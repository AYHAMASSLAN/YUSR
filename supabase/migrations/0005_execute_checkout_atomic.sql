-- ============================================================================
-- Yusr (يُسر) — Migration 0005: Atomic Checkout Execution RPC
-- ============================================================================
-- Depends on: 0001_core_users_kyc.sql .. 0004_ledger.sql
--
-- Purpose:
--   Provides the ACID PostgreSQL transaction boundary for Yusr split checkout:
--     1. Serializes user checkout & validates KYC + Tier limits (FOR UPDATE).
--     2. Locks products in deterministic UUID order & deducts stock.
--     3. Locks active Islamic Bank Pool & deducts available_liquidity.
--     4. Splits items deterministically (Micro-Credit -> Murabaha -> Cash)
--        grouped per Merchant (1 contract per Merchant per route type).
--     5. Generates exact NUMERIC(14,2) installment schedules with zero rounding
--        drift and HARD zero-riba fields (late_fee_bps = 0, late_fee_amount = 0.00).
--     6. Posts balanced double-entry records into ledger_transactions.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helper 1: Ensure / Retrieve a Ledger Account in the Chart of Accounts
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_ledger_account(
  p_account_code TEXT,
  p_account_name TEXT,
  p_account_type TEXT,
  p_owner_type TEXT,
  p_owner_id UUID DEFAULT NULL,
  p_currency CHAR(3) DEFAULT 'SAR'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account_id UUID;
BEGIN
  INSERT INTO public.ledger_accounts (
    account_code,
    account_name,
    account_type,
    owner_type,
    owner_id,
    currency
  )
  VALUES (
    p_account_code,
    p_account_name,
    p_account_type,
    p_owner_type,
    p_owner_id,
    p_currency
  )
  ON CONFLICT (account_code) DO NOTHING
  RETURNING id INTO v_account_id;

  IF v_account_id IS NULL THEN
    SELECT id INTO v_account_id
    FROM public.ledger_accounts
    WHERE account_code = p_account_code;
  END IF;

  RETURN v_account_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Helper 2: Post an Idempotent Double-Entry Ledger Transaction & Update Balances
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.post_ledger_entry(
  p_transaction_group_id UUID,
  p_idempotency_key TEXT,
  p_debit_account_id UUID,
  p_credit_account_id UUID,
  p_amount NUMERIC(14,2),
  p_entry_type TEXT,
  p_contract_id UUID,
  p_description TEXT,
  p_metadata JSONB DEFAULT '{}'::jsonb,
  p_currency CHAR(3) DEFAULT 'SAR'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tx_id UUID;
  v_debit_type TEXT;
  v_credit_type TEXT;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0.00 THEN
    RAISE EXCEPTION 'INVALID_LEDGER_AMOUNT: Ledger entry amount must be positive.';
  END IF;

  -- Lock accounts in deterministic ID order to prevent deadlocks
  IF p_debit_account_id < p_credit_account_id THEN
    SELECT account_type INTO v_debit_type
    FROM public.ledger_accounts WHERE id = p_debit_account_id FOR UPDATE;
    SELECT account_type INTO v_credit_type
    FROM public.ledger_accounts WHERE id = p_credit_account_id FOR UPDATE;
  ELSE
    SELECT account_type INTO v_credit_type
    FROM public.ledger_accounts WHERE id = p_credit_account_id FOR UPDATE;
    SELECT account_type INTO v_debit_type
    FROM public.ledger_accounts WHERE id = p_debit_account_id FOR UPDATE;
  END IF;

  -- Idempotent insert into append-only ledger_transactions
  INSERT INTO public.ledger_transactions (
    transaction_group_id,
    idempotency_key,
    debit_account_id,
    credit_account_id,
    amount,
    currency,
    entry_type,
    contract_id,
    description,
    metadata
  )
  VALUES (
    p_transaction_group_id,
    p_idempotency_key,
    p_debit_account_id,
    p_credit_account_id,
    p_amount,
    p_currency,
    p_entry_type,
    p_contract_id,
    p_description,
    COALESCE(p_metadata, '{}'::jsonb)
  )
  ON CONFLICT (idempotency_key, debit_account_id, credit_account_id) DO NOTHING
  RETURNING id INTO v_tx_id;

  -- Only mutate account balances if this insert actually occurred
  IF v_tx_id IS NOT NULL THEN
    -- Debit increases Asset/Expense; decreases Liability/Equity/Revenue
    UPDATE public.ledger_accounts
    SET balance = balance + CASE
      WHEN v_debit_type IN ('asset', 'expense') THEN p_amount
      ELSE -p_amount
    END
    WHERE id = p_debit_account_id;

    -- Credit increases Liability/Equity/Revenue; decreases Asset/Expense
    UPDATE public.ledger_accounts
    SET balance = balance + CASE
      WHEN v_credit_type IN ('liability', 'equity', 'revenue') THEN p_amount
      ELSE -p_amount
    END
    WHERE id = p_credit_account_id;
  ELSE
    SELECT id INTO v_tx_id
    FROM public.ledger_transactions
    WHERE idempotency_key = p_idempotency_key
      AND debit_account_id = p_debit_account_id
      AND credit_account_id = p_credit_account_id;
  END IF;

  RETURN v_tx_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- Main RPC: execute_checkout_atomic(p_user_id UUID, p_payload JSONB)
-- ----------------------------------------------------------------------------
-- Expected p_payload JSONB structure:
-- {
--   "idempotency_key": "uuid-or-client-key",
--   "requested_tenor_months": 6,
--   "items": [
--     { "product_id": "uuid", "quantity": 2 }
--   ]
-- }
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.execute_checkout_atomic(
  p_user_id UUID,
  p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_idempotency_key TEXT;
  v_checkout_session_id UUID;
  v_tx_group_id UUID := gen_random_uuid();
  v_requested_tenor INTEGER;

  -- User, KYC & Underwriting state
  v_user_status TEXT;
  v_kyc_status TEXT;
  v_tier CHAR(1) := 'D';
  v_micro_limit NUMERIC(14,2) := 0.00;
  v_murabaha_limit NUMERIC(14,2) := 0.00;
  v_min_down_bps INTEGER := 10000;
  v_max_tenor INTEGER := 1;
  v_used_micro NUMERIC(14,2) := 0.00;
  v_used_murabaha NUMERIC(14,2) := 0.00;
  v_avail_micro NUMERIC(14,2) := 0.00;
  v_avail_murabaha NUMERIC(14,2) := 0.00;

  -- Selected Islamic Bank Liquidity Pool
  v_pool_id UUID;
  v_pool_name TEXT;
  v_pool_avail_liq NUMERIC(14,2) := 0.00;
  v_pool_markup_bps INTEGER := 0;

  -- Line-item & routing loop variables
  v_item_rec RECORD;
  v_line_total NUMERIC(14,2);
  v_req_down NUMERIC(14,2);
  v_req_principal NUMERIC(14,2);
  v_assigned_route TEXT;

  -- Per-Merchant Contract Creation variables
  v_merchant_rec RECORD;
  v_contract_id UUID;
  v_contract_number TEXT;
  v_gross_amount NUMERIC(14,2);
  v_down_amount NUMERIC(14,2);
  v_financed_principal NUMERIC(14,2);
  v_profit_amount NUMERIC(14,2);
  v_total_payable NUMERIC(14,2);
  v_effective_tenor INTEGER;
  v_bank_purchased_at TIMESTAMPTZ;
  v_customer_accepted_at TIMESTAMPTZ;

  -- Installment schedule calculation variables
  v_inst_idx INTEGER;
  v_base_principal NUMERIC(14,2);
  v_base_profit NUMERIC(14,2);
  v_inst_principal NUMERIC(14,2);
  v_inst_profit NUMERIC(14,2);
  v_inst_due_amount NUMERIC(14,2);
  v_inst_due_date DATE;

  -- Ledger accounts
  v_acc_platform_cash UUID;
  v_acc_user_qard UUID;
  v_acc_user_murabaha UUID;
  v_acc_merchant_payable UUID;
  v_acc_pool_inventory UUID;
  v_acc_pool_profit UUID;

  -- Summary & Response Builders
  v_existing_contracts JSONB;
  v_ledger_meta JSONB;
  v_contracts_json JSONB := '[]'::jsonb;
  v_contract_obj JSONB;
  v_installments_json JSONB;
  v_grand_total NUMERIC(14,2) := 0.00;
  v_total_cash_due_now NUMERIC(14,2) := 0.00;
  v_total_micro_financed NUMERIC(14,2) := 0.00;
  v_total_murabaha_principal NUMERIC(14,2) := 0.00;
  v_total_murabaha_profit NUMERIC(14,2) := 0.00;
BEGIN
  -- 1. Validate inputs
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_INPUT: p_user_id is required.';
  END IF;

  IF p_payload IS NULL OR jsonb_typeof(p_payload->'items') <> 'array' OR jsonb_array_length(p_payload->'items') = 0 THEN
    RAISE EXCEPTION 'INVALID_CART: items must be a non-empty JSON array.';
  END IF;

  v_idempotency_key := NULLIF(trim(COALESCE(p_payload->>'idempotency_key', '')), '');
  IF v_idempotency_key IS NULL THEN
    v_idempotency_key := gen_random_uuid()::text;
  END IF;

  -- 2. Lock User Row (serializes concurrent checkouts for this user)
  SELECT status INTO v_user_status
  FROM public.users
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'USER_NOT_FOUND: Customer profile does not exist.';
  END IF;

  IF v_user_status <> 'active' THEN
    RAISE EXCEPTION 'ACCOUNT_RESTRICTED: Customer account status is %.', v_user_status;
  END IF;

  -- 3. Idempotency Replay Check (exact JSONB metadata lookup scoped to p_user_id)
  SELECT jsonb_agg(
    jsonb_build_object(
      'contract_id', c.id,
      'contract_number', c.contract_number,
      'contract_type', c.contract_type,
      'status', c.status,
      'merchant_id', c.merchant_id,
      'bank_pool_id', c.bank_pool_id,
      'gross_order_amount', c.gross_order_amount,
      'down_payment_amount', c.down_payment_amount,
      'financed_principal', c.financed_principal,
      'profit_amount', c.profit_amount,
      'total_payable', c.total_payable,
      'tenor_months', c.tenor_months,
      'late_fee_bps', c.late_fee_bps,
      'installments', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'id', i.id,
            'installment_number', i.installment_number,
            'due_date', i.due_date,
            'principal_component', i.principal_component,
            'profit_component', i.profit_component,
            'amount_due', i.amount_due,
            'late_fee_bps', i.late_fee_bps,
            'late_fee_amount', i.late_fee_amount,
            'status', i.status
          ) ORDER BY i.installment_number
        )
        FROM public.installments i
        WHERE i.contract_id = c.id
      ), '[]'::jsonb)
    ) ORDER BY c.created_at, c.contract_number
  )
  INTO v_existing_contracts
  FROM public.contracts c
  WHERE c.user_id = p_user_id
    AND c.id IN (
      SELECT DISTINCT lt.contract_id
      FROM public.ledger_transactions lt
      WHERE lt.metadata->>'user_id' = p_user_id::text
        AND lt.metadata->>'idempotency_key' = v_idempotency_key
        AND lt.contract_id IS NOT NULL
    );

  IF v_existing_contracts IS NOT NULL THEN
    RETURN jsonb_build_object(
      'confirmed', true,
      'idempotent_replay', true,
      'idempotency_key', v_idempotency_key,
      'contracts', v_existing_contracts
    );
  END IF;

  -- 4. Lock & Verify KYC Record
  SELECT status INTO v_kyc_status
  FROM public.kyc_records
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND OR v_kyc_status <> 'verified' THEN
    RAISE EXCEPTION 'KYC_NOT_VERIFIED: Verified KYC is required before executing checkout.';
  END IF;

  -- 5. Lock Active Credit Score & Compute Remaining Exposure Headroom
  SELECT
    tier,
    micro_credit_limit,
    murabaha_limit,
    min_down_payment_bps,
    max_tenor_months
  INTO
    v_tier,
    v_micro_limit,
    v_murabaha_limit,
    v_min_down_bps,
    v_max_tenor
  FROM public.credit_scores
  WHERE user_id = p_user_id
    AND is_current = true
    AND expires_at > now()
  FOR UPDATE;

  IF NOT FOUND THEN
    -- Safe fallback: Tier D (Cash-Only) if no active credit score snapshot exists
    v_tier := 'D';
    v_micro_limit := 0.00;
    v_murabaha_limit := 0.00;
    v_min_down_bps := 10000;
    v_max_tenor := 1;
  END IF;

  -- Lock open contracts for this user to sum authoritative exposure
  FOR v_item_rec IN
    SELECT contract_type, financed_principal
    FROM public.contracts
    WHERE user_id = p_user_id
      AND status IN ('pending_bank_purchase', 'bank_owned', 'murabaha_offered', 'active')
    FOR UPDATE
  LOOP
    IF v_item_rec.contract_type = 'micro_credit' THEN
      v_used_micro := v_used_micro + v_item_rec.financed_principal;
    ELSIF v_item_rec.contract_type = 'murabaha' THEN
      v_used_murabaha := v_used_murabaha + v_item_rec.financed_principal;
    END IF;
  END LOOP;

  v_avail_micro := GREATEST(0.00, v_micro_limit - v_used_micro);
  v_avail_murabaha := GREATEST(0.00, v_murabaha_limit - v_used_murabaha);

  v_requested_tenor := COALESCE((p_payload->>'requested_tenor_months')::INTEGER, v_max_tenor);
  v_requested_tenor := LEAST(GREATEST(v_requested_tenor, 1), v_max_tenor);

  -- 6. Lock Best Active Islamic Bank Liquidity Pool (if Tier allows financing)
  IF v_tier <> 'D' THEN
    SELECT id, partner_bank_name, available_liquidity, murabaha_markup_bps
    INTO v_pool_id, v_pool_name, v_pool_avail_liq, v_pool_markup_bps
    FROM public.bank_pools
    WHERE is_active = true
      AND available_liquidity > 0.00
    ORDER BY murabaha_markup_bps ASC, id ASC
    LIMIT 1
    FOR UPDATE;
  END IF;

  -- 7. Stage & Lock Requested Products in Deterministic UUID Order
  CREATE TEMP TABLE tmp_checkout_lines (
    product_id UUID NOT NULL,
    merchant_id UUID NOT NULL,
    product_name TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    unit_cost_price NUMERIC(14,2) NOT NULL,
    unit_price NUMERIC(14,2) NOT NULL,
    line_total NUMERIC(14,2) NOT NULL,
    route_type TEXT NOT NULL
  ) ON COMMIT DROP;

  FOR v_item_rec IN
    WITH consolidated_cart AS (
      SELECT
        (elem->>'product_id')::UUID AS product_id,
        SUM((elem->>'quantity')::INTEGER)::INTEGER AS quantity
      FROM jsonb_array_elements(p_payload->'items') AS elem
      GROUP BY (elem->>'product_id')::UUID
    )
    SELECT
      cc.product_id,
      cc.quantity,
      p.merchant_id,
      p.name AS product_name,
      p.unit_price,
      p.cost_price,
      p.stock_qty,
      p.is_sharia_approved,
      p.allows_murabaha,
      p.allows_micro_credit,
      p.is_active,
      m.status AS merchant_status,
      m.is_sharia_certified AS merchant_sharia_certified
    FROM consolidated_cart cc
    JOIN public.products p ON p.id = cc.product_id
    JOIN public.merchants m ON m.id = p.merchant_id
    ORDER BY p.id ASC
    FOR UPDATE OF p
  LOOP
    IF v_item_rec.quantity <= 0 OR v_item_rec.quantity > 100 THEN
      RAISE EXCEPTION 'INVALID_QUANTITY: Quantity for product % must be 1..100.', v_item_rec.product_id;
    END IF;

    IF NOT v_item_rec.is_active OR NOT v_item_rec.is_sharia_approved THEN
      RAISE EXCEPTION 'SHARIA_OR_CATALOG_ERROR: Product % is inactive or not Sharia-approved.', v_item_rec.product_name;
    END IF;

    IF v_item_rec.merchant_status <> 'active' OR NOT v_item_rec.merchant_sharia_certified THEN
      RAISE EXCEPTION 'MERCHANT_INACTIVE: Merchant for product % is inactive or uncertified.', v_item_rec.product_name;
    END IF;

    IF v_item_rec.stock_qty < v_item_rec.quantity THEN
      RAISE EXCEPTION 'INSUFFICIENT_STOCK: Product % has % in stock, % requested.',
        v_item_rec.product_name, v_item_rec.stock_qty, v_item_rec.quantity;
    END IF;

    -- Verify every requested item resolved (check count later too)
    v_line_total := ROUND(v_item_rec.unit_price * v_item_rec.quantity, 2);
    v_grand_total := v_grand_total + v_line_total;

    -- Deduct authoritative inventory atomically
    UPDATE public.products
    SET stock_qty = stock_qty - v_item_rec.quantity
    WHERE id = v_item_rec.product_id;

    -- Deterministic Split Route Assignment (Micro-Credit -> Murabaha -> Cash)
    IF v_tier <> 'D'
       AND v_item_rec.allows_micro_credit
       AND v_avail_micro >= v_line_total THEN
      v_assigned_route := 'micro_credit';
      v_avail_micro := v_avail_micro - v_line_total;
    ELSE
      v_req_down := ROUND(v_line_total * (v_min_down_bps::NUMERIC / 10000.0), 2);
      v_req_principal := v_line_total - v_req_down;

      IF v_tier <> 'D'
         AND v_item_rec.allows_murabaha
         AND v_pool_id IS NOT NULL
         AND v_avail_murabaha >= v_req_principal
         AND v_pool_avail_liq >= v_req_principal THEN
        v_assigned_route := 'murabaha';
        v_avail_murabaha := v_avail_murabaha - v_req_principal;
        v_pool_avail_liq := v_pool_avail_liq - v_req_principal;
      ELSE
        v_assigned_route := 'cash';
      END IF;
    END IF;

    INSERT INTO tmp_checkout_lines (
      product_id,
      merchant_id,
      product_name,
      quantity,
      unit_cost_price,
      unit_price,
      line_total,
      route_type
    )
    VALUES (
      v_item_rec.product_id,
      v_item_rec.merchant_id,
      v_item_rec.product_name,
      v_item_rec.quantity,
      v_item_rec.cost_price,
      v_item_rec.unit_price,
      v_line_total,
      v_assigned_route
    );
  END LOOP;

  -- Ensure all distinct product_ids in payload existed in catalog
  IF (SELECT COUNT(DISTINCT (elem->>'product_id')::UUID) FROM jsonb_array_elements(p_payload->'items') AS elem)
     <> (SELECT COUNT(*) FROM tmp_checkout_lines) THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND: One or more cart product_ids do not exist.';
  END IF;

  -- 8. Ensure Platform & User Ledger Accounts Exist
  v_checkout_session_id := gen_random_uuid();
  v_ledger_meta := jsonb_build_object(
    'user_id', p_user_id::text,
    'idempotency_key', v_idempotency_key,
    'checkout_session_id', v_checkout_session_id::text
  );

  v_acc_platform_cash := public.ensure_ledger_account(
    'PLATFORM:CASH_CLEARING',
    'Yusr Platform Cash Clearing Account',
    'asset',
    'platform',
    NULL
  );

  v_acc_user_qard := public.ensure_ledger_account(
    'USER:' || p_user_id::text || ':QARD_RECEIVABLE',
    'Customer Qard Hasan Receivable',
    'asset',
    'user',
    p_user_id
  );

  v_acc_user_murabaha := public.ensure_ledger_account(
    'USER:' || p_user_id::text || ':MURABAHA_RECEIVABLE',
    'Customer Murabaha Receivable',
    'asset',
    'user',
    p_user_id
  );

  IF v_pool_id IS NOT NULL THEN
    v_acc_pool_inventory := public.ensure_ledger_account(
      'BANK_POOL:' || v_pool_id::text || ':INVENTORY',
      'Bank Pool Murabaha Asset Inventory',
      'asset',
      'bank_pool',
      v_pool_id
    );
    v_acc_pool_profit := public.ensure_ledger_account(
      'BANK_POOL:' || v_pool_id::text || ':PROFIT_REVENUE',
      'Bank Pool Fixed Murabaha Profit Revenue',
      'revenue',
      'bank_pool',
      v_pool_id
    );
  END IF;

  -- 9. Materialize Contracts, Items, Installments & Double-Entry Ledger Postings
  --    Grouped per (merchant_id, route_type)
  FOR v_merchant_rec IN
    SELECT
      merchant_id,
      route_type,
      SUM(line_total) AS group_gross
    FROM tmp_checkout_lines
    GROUP BY merchant_id, route_type
    ORDER BY merchant_id, route_type
  LOOP
    v_contract_id := gen_random_uuid();
    v_gross_amount := v_merchant_rec.group_gross;
    v_contract_number := 'YSR-' || upper(substr(v_merchant_rec.route_type, 1, 3))
      || '-' || to_char(now(), 'YYYYMMDD')
      || '-' || upper(substr(replace(v_contract_id::text, '-', ''), 1, 8));

    v_acc_merchant_payable := public.ensure_ledger_account(
      'MERCHANT:' || v_merchant_rec.merchant_id::text || ':PAYABLE',
      'Merchant Settlement Payable',
      'liability',
      'merchant',
      v_merchant_rec.merchant_id
    );

    -- Branch by Sharia Contract Type
    IF v_merchant_rec.route_type = 'cash' THEN
      v_down_amount := v_gross_amount;
      v_financed_principal := 0.00;
      v_profit_amount := 0.00;
      v_total_payable := 0.00;
      v_effective_tenor := 1;
      v_total_cash_due_now := v_total_cash_due_now + v_down_amount;

      INSERT INTO public.contracts (
        id, contract_number, checkout_session_id, user_id, merchant_id, bank_pool_id,
        contract_type, status, gross_order_amount, down_payment_amount,
        financed_principal, profit_amount, total_payable, markup_bps, late_fee_bps,
        tenor_months, completed_at
      )
      VALUES (
        v_contract_id, v_contract_number, v_checkout_session_id, p_user_id, v_merchant_rec.merchant_id, NULL,
        'cash', 'completed', v_gross_amount, v_down_amount,
        0.00, 0.00, 0.00, 0, 0,
        1, now()
      );

      -- Ledger: Debit Platform Cash Clearing, Credit Merchant Payable
      PERFORM public.post_ledger_entry(
        v_tx_group_id,
        p_user_id::text || ':' || v_idempotency_key || ':' || v_contract_id::text || ':cash',
        v_acc_platform_cash,
        v_acc_merchant_payable,
        v_gross_amount,
        'cash_settlement',
        v_contract_id,
        'Cash checkout settlement for contract ' || v_contract_number,
        v_ledger_meta
      );

    ELSIF v_merchant_rec.route_type = 'micro_credit' THEN
      v_down_amount := 0.00;
      v_financed_principal := v_gross_amount;
      v_profit_amount := 0.00;
      v_total_payable := v_financed_principal;
      v_effective_tenor := LEAST(v_requested_tenor, 3); -- Qard Hasan short-term (up to 3 months)
      v_total_micro_financed := v_total_micro_financed + v_financed_principal;

      INSERT INTO public.contracts (
        id, contract_number, checkout_session_id, user_id, merchant_id, bank_pool_id,
        contract_type, status, gross_order_amount, down_payment_amount,
        financed_principal, profit_amount, total_payable, markup_bps, late_fee_bps,
        tenor_months
      )
      VALUES (
        v_contract_id, v_contract_number, v_checkout_session_id, p_user_id, v_merchant_rec.merchant_id, NULL,
        'micro_credit', 'active', v_gross_amount, 0.00,
        v_financed_principal, 0.00, v_total_payable, 0, 0,
        v_effective_tenor
      );

      -- Ledger: Debit Customer Qard Receivable, Credit Merchant Payable
      PERFORM public.post_ledger_entry(
        v_tx_group_id,
        p_user_id::text || ':' || v_idempotency_key || ':' || v_contract_id::text || ':qard',
        v_acc_user_qard,
        v_acc_merchant_payable,
        v_financed_principal,
        'micro_credit_disbursement',
        v_contract_id,
        'Qard Hasan (0% profit) micro-credit disbursement for ' || v_contract_number,
        v_ledger_meta
      );

    ELSE -- 'murabaha'
      v_down_amount := ROUND(v_gross_amount * (v_min_down_bps::NUMERIC / 10000.0), 2);
      v_financed_principal := v_gross_amount - v_down_amount;
      v_effective_tenor := v_requested_tenor;
      v_profit_amount := ROUND(
        v_financed_principal * (v_pool_markup_bps::NUMERIC / 10000.0) * (v_effective_tenor::NUMERIC / 12.0),
        2
      );
      v_total_payable := v_financed_principal + v_profit_amount;

      -- Sequential Sharia Ownership Timestamps (Qabd before Resale)
      v_bank_purchased_at := clock_timestamp();
      v_customer_accepted_at := clock_timestamp();

      v_total_cash_due_now := v_total_cash_due_now + v_down_amount;
      v_total_murabaha_principal := v_total_murabaha_principal + v_financed_principal;
      v_total_murabaha_profit := v_total_murabaha_profit + v_profit_amount;

      -- Deduct Islamic Bank Pool Liquidity
      UPDATE public.bank_pools
      SET available_liquidity = available_liquidity - v_financed_principal
      WHERE id = v_pool_id;

      INSERT INTO public.contracts (
        id, contract_number, checkout_session_id, user_id, merchant_id, bank_pool_id,
        contract_type, status, gross_order_amount, down_payment_amount,
        financed_principal, profit_amount, total_payable, markup_bps, late_fee_bps,
        tenor_months, bank_purchased_at, customer_accepted_at
      )
      VALUES (
        v_contract_id, v_contract_number, v_checkout_session_id, p_user_id, v_merchant_rec.merchant_id, v_pool_id,
        'murabaha', 'active', v_gross_amount, v_down_amount,
        v_financed_principal, v_profit_amount, v_total_payable, v_pool_markup_bps, 0,
        v_effective_tenor, v_bank_purchased_at, v_customer_accepted_at
      );

      -- Ledger Leg 1: Customer Down Payment (if > 0)
      IF v_down_amount > 0.00 THEN
        PERFORM public.post_ledger_entry(
          v_tx_group_id,
          p_user_id::text || ':' || v_idempotency_key || ':' || v_contract_id::text || ':down_payment',
          v_acc_platform_cash,
          v_acc_merchant_payable,
          v_down_amount,
          'down_payment',
          v_contract_id,
          'Murabaha down payment for ' || v_contract_number,
          v_ledger_meta
        );
      END IF;

      -- Ledger Leg 2: Bank Pool purchases asset from Merchant (Qabd)
      IF v_financed_principal > 0.00 THEN
        PERFORM public.post_ledger_entry(
          v_tx_group_id,
          p_user_id::text || ':' || v_idempotency_key || ':' || v_contract_id::text || ':bank_purchase',
          v_acc_pool_inventory,
          v_acc_merchant_payable,
          v_financed_principal,
          'bank_asset_purchase',
          v_contract_id,
          'Bank Pool asset purchase from merchant for ' || v_contract_number,
          v_ledger_meta
        );

        -- Ledger Leg 3: Bank Pool resells asset to Customer at cost
        PERFORM public.post_ledger_entry(
          v_tx_group_id,
          p_user_id::text || ':' || v_idempotency_key || ':' || v_contract_id::text || ':murabaha_sale',
          v_acc_user_murabaha,
          v_acc_pool_inventory,
          v_financed_principal,
          'murabaha_sale_booking',
          v_contract_id,
          'Murabaha cost principal sale to customer for ' || v_contract_number,
          v_ledger_meta
        );
      END IF;

      -- Ledger Leg 4: Fixed Murabaha Profit booking (if > 0)
      IF v_profit_amount > 0.00 THEN
        PERFORM public.post_ledger_entry(
          v_tx_group_id,
          p_user_id::text || ':' || v_idempotency_key || ':' || v_contract_id::text || ':murabaha_profit',
          v_acc_user_murabaha,
          v_acc_pool_profit,
          v_profit_amount,
          'murabaha_profit_booking',
          v_contract_id,
          'Fixed Murabaha profit booking for ' || v_contract_number,
          v_ledger_meta
        );
      END IF;
    END IF;

    -- Insert Contract Items Snapshot
    INSERT INTO public.contract_items (
      contract_id, product_id, bundle_id, quantity,
      unit_cost_price, unit_sale_price, line_total
    )
    SELECT
      v_contract_id, product_id, NULL, quantity,
      unit_cost_price, unit_price, line_total
    FROM tmp_checkout_lines
    WHERE merchant_id = v_merchant_rec.merchant_id
      AND route_type = v_merchant_rec.route_type;

    -- Generate Fixed Installments (for micro_credit and murabaha with financed_principal > 0)
    v_installments_json := '[]'::jsonb;

    IF v_merchant_rec.route_type IN ('micro_credit', 'murabaha') AND v_total_payable > 0.00 THEN
      -- Guard against tiny principals smaller than 0.01 * tenor
      IF v_financed_principal < (v_effective_tenor * 0.01) THEN
        v_effective_tenor := 1;
        UPDATE public.contracts
        SET tenor_months = 1
        WHERE id = v_contract_id;
      END IF;

      v_base_principal := TRUNC(v_financed_principal / v_effective_tenor, 2);
      v_base_profit := TRUNC(v_profit_amount / v_effective_tenor, 2);

      FOR v_inst_idx IN 1..v_effective_tenor LOOP
        IF v_inst_idx < v_effective_tenor THEN
          v_inst_principal := v_base_principal;
          v_inst_profit := v_base_profit;
        ELSE
          -- Assign exact remainder cents on final installment (zero drift)
          v_inst_principal := v_financed_principal - (v_base_principal * (v_effective_tenor - 1));
          v_inst_profit := v_profit_amount - (v_base_profit * (v_effective_tenor - 1));
        END IF;

        v_inst_due_amount := v_inst_principal + v_inst_profit;
        v_inst_due_date := (CURRENT_DATE + (v_inst_idx || ' months')::INTERVAL)::DATE;

        INSERT INTO public.installments (
          contract_id,
          user_id,
          installment_number,
          due_date,
          principal_component,
          profit_component,
          amount_due,
          amount_paid,
          late_fee_bps,
          late_fee_amount,
          status
        )
        VALUES (
          v_contract_id,
          p_user_id,
          v_inst_idx,
          v_inst_due_date,
          v_inst_principal,
          v_inst_profit,
          v_inst_due_amount,
          0.00,
          0,    -- HARD ZERO-RIBA INVARIANT
          0.00, -- HARD ZERO-RIBA INVARIANT
          'scheduled'
        );
      END LOOP;

      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'id', i.id,
          'installment_number', i.installment_number,
          'due_date', i.due_date,
          'principal_component', i.principal_component,
          'profit_component', i.profit_component,
          'amount_due', i.amount_due,
          'late_fee_bps', i.late_fee_bps,
          'late_fee_amount', i.late_fee_amount,
          'status', i.status
        ) ORDER BY i.installment_number
      ), '[]'::jsonb)
      INTO v_installments_json
      FROM public.installments i
      WHERE i.contract_id = v_contract_id;
    END IF;

    v_contract_obj := jsonb_build_object(
      'contract_id', v_contract_id,
      'contract_number', v_contract_number,
      'contract_type', v_merchant_rec.route_type,
      'status', CASE WHEN v_merchant_rec.route_type = 'cash' THEN 'completed' ELSE 'active' END,
      'merchant_id', v_merchant_rec.merchant_id,
      'bank_pool_id', CASE WHEN v_merchant_rec.route_type = 'murabaha' THEN v_pool_id ELSE NULL END,
      'gross_order_amount', v_gross_amount,
      'down_payment_amount', v_down_amount,
      'financed_principal', v_financed_principal,
      'profit_amount', v_profit_amount,
      'total_payable', v_total_payable,
      'tenor_months', v_effective_tenor,
      'late_fee_bps', 0,
      'installments', v_installments_json
    );

    v_contracts_json := v_contracts_json || jsonb_build_array(v_contract_obj);
  END LOOP;

  -- 10. Return Confirmed Atomic Execution Summary
  RETURN jsonb_build_object(
    'confirmed', true,
    'idempotent_replay', false,
    'checkout_session_id', v_checkout_session_id,
    'idempotency_key', v_idempotency_key,
    'transaction_group_id', v_tx_group_id,
    'tier_applied', v_tier,
    'summary', jsonb_build_object(
      'cart_grand_total', v_grand_total,
      'due_now_cash_total', v_total_cash_due_now,
      'micro_credit_financed_total', v_total_micro_financed,
      'murabaha_financed_principal_total', v_total_murabaha_principal,
      'murabaha_fixed_profit_total', v_total_murabaha_profit
    ),
    'sharia_compliance', jsonb_build_object(
      'zero_riba_verified', true,
      'late_fee_bps', 0,
      'late_fee_amount', 0.00,
      'compounding_interest', false
    ),
    'contracts', v_contracts_json
  );
END;
$$;

-- Security Hardening: Restrict RPC execution strictly to service_role
REVOKE ALL ON FUNCTION public.ensure_ledger_account(TEXT, TEXT, TEXT, TEXT, UUID, CHAR) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.post_ledger_entry(UUID, TEXT, UUID, UUID, NUMERIC, TEXT, UUID, TEXT, JSONB, CHAR) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.execute_checkout_atomic(UUID, JSONB) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.execute_checkout_atomic(UUID, JSONB) TO service_role;
