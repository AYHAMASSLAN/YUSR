-- ============================================================================
-- Yusr (يُسر) — Migration 0006: Atomic Installment Repayment RPC
-- ============================================================================
-- Depends on: 0001..0005 (uses ensure_ledger_account & post_ledger_entry)
-- Sharia Invariants:
--   1. Zero late fees (late_fee_bps = 0, late_fee_amount = 0.00).
--   2. Exact remaining-due validation (no partial/overpayment drift).
--   3. Murabaha principal component replenishes Islamic Bank Pool liquidity.
--   4. Balanced double-entry ledger posting via post_ledger_entry.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.process_installment_repayment(
  p_installment_id UUID,
  p_amount NUMERIC,
  p_payment_method TEXT,
  p_idempotency_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_idem_key TEXT;
  v_pay_method TEXT;
  v_amount NUMERIC(14,2);
  v_remaining_due NUMERIC(14,2);

  v_inst RECORD;
  v_contract RECORD;
  v_user_status TEXT;

  v_unpaid_count INTEGER := 0;
  v_overdue_count INTEGER := 0;
  v_contract_completed BOOLEAN := false;
  v_account_unfrozen BOOLEAN := false;
  v_principal_replenished NUMERIC(14,2) := 0.00;

  v_tx_group_id UUID := gen_random_uuid();
  v_acc_platform_cash UUID;
  v_acc_user_receivable UUID;
  v_ledger_meta JSONB;
BEGIN
  -- 1. Validate inputs
  IF p_installment_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_INPUT: p_installment_id is required.';
  END IF;

  v_amount := ROUND(COALESCE(p_amount, 0.00), 2);
  IF v_amount <= 0.00 THEN
    RAISE EXCEPTION 'INVALID_AMOUNT: Repayment amount must be greater than 0.00.';
  END IF;

  v_pay_method := lower(trim(COALESCE(p_payment_method, '')));
  IF v_pay_method NOT IN ('sham_cash', 'bank_transfer', 'cash_agent') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD: Supported methods are sham_cash, bank_transfer, cash_agent.';
  END IF;

  v_idem_key := NULLIF(trim(COALESCE(p_idempotency_key, '')), '');
  IF v_idem_key IS NULL THEN
    RAISE EXCEPTION 'INVALID_INPUT: p_idempotency_key is required.';
  END IF;

  -- 2. Lock Installment Row
  SELECT * INTO v_inst
  FROM public.installments
  WHERE id = p_installment_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INSTALLMENT_NOT_FOUND: Installment % does not exist.', p_installment_id;
  END IF;

  -- 3. Idempotency Replay Check
  IF EXISTS (
    SELECT 1
    FROM public.ledger_transactions lt
    WHERE lt.contract_id = v_inst.contract_id
      AND lt.entry_type = 'installment_repayment'
      AND lt.metadata->>'installment_id' = p_installment_id::text
      AND lt.metadata->>'idempotency_key' = v_idem_key
  ) THEN
    SELECT status INTO v_contract FROM public.contracts WHERE id = v_inst.contract_id;
    RETURN jsonb_build_object(
      'status', 'paid',
      'idempotent_replay', true,
      'installment_id', v_inst.id,
      'contract_id', v_inst.contract_id,
      'user_id', v_inst.user_id,
      'amount_paid', v_inst.amount_paid,
      'principal_replenished', 0.00,
      'contract_completed', (v_contract.status = 'completed'),
      'account_unfrozen', false
    );
  END IF;

  IF v_inst.status = 'paid' THEN
    RAISE EXCEPTION 'INSTALLMENT_ALREADY_PAID: Installment % is already settled.', p_installment_id;
  END IF;

  IF v_inst.status NOT IN ('scheduled', 'due', 'partial', 'overdue') THEN
    RAISE EXCEPTION 'INVALID_INSTALLMENT_STATE: Cannot repay installment in status %.', v_inst.status;
  END IF;

  v_remaining_due := ROUND(v_inst.amount_due - v_inst.amount_paid, 2);
  IF v_amount <> v_remaining_due THEN
    RAISE EXCEPTION 'AMOUNT_MISMATCH: Expected exact remaining due %, received %.', v_remaining_due, v_amount;
  END IF;

  -- 4. Lock Parent Contract, User, and Bank Pool (if Murabaha)
  SELECT * INTO v_contract
  FROM public.contracts
  WHERE id = v_inst.contract_id
  FOR UPDATE;

  SELECT status INTO v_user_status
  FROM public.users
  WHERE id = v_inst.user_id
  FOR UPDATE;

  IF v_contract.contract_type = 'murabaha' AND v_contract.bank_pool_id IS NOT NULL THEN
    PERFORM 1 FROM public.bank_pools WHERE id = v_contract.bank_pool_id FOR UPDATE;
  END IF;

  -- 5. Mark Installment Paid (preserving zero-riba invariants)
  UPDATE public.installments
  SET
    amount_paid = amount_due,
    status = 'paid',
    paid_at = now()
  WHERE id = p_installment_id;

  -- 6. Replenish Islamic Bank Pool Principal Liquidity (capital turnover for Murabaha)
  IF v_contract.contract_type = 'murabaha'
     AND v_contract.bank_pool_id IS NOT NULL
     AND v_inst.principal_component > 0.00 THEN
    v_principal_replenished := v_inst.principal_component;

    UPDATE public.bank_pools
    SET available_liquidity = LEAST(
      total_capital - reserved_liquidity,
      available_liquidity + v_principal_replenished
    )
    WHERE id = v_contract.bank_pool_id;
  END IF;

  -- 7. Complete Parent Contract if All Installments Are Paid
  SELECT COUNT(*) INTO v_unpaid_count
  FROM public.installments
  WHERE contract_id = v_contract.id
    AND status NOT IN ('paid', 'written_off');

  IF v_unpaid_count = 0 AND v_contract.status <> 'completed' THEN
    UPDATE public.contracts
    SET
      status = 'completed',
      completed_at = now()
    WHERE id = v_contract.id;
    v_contract_completed := true;
  ELSIF v_contract.status = 'completed' THEN
    v_contract_completed := true;
  END IF;

  -- 8. Unfreeze User Account if Frozen & No Other Overdue Installments Remain
  IF v_user_status = 'frozen' THEN
    SELECT COUNT(*) INTO v_overdue_count
    FROM public.installments
    WHERE user_id = v_inst.user_id
      AND status = 'overdue';

    IF v_overdue_count = 0 THEN
      UPDATE public.users
      SET status = 'active'
      WHERE id = v_inst.user_id;
      v_account_unfrozen := true;
    END IF;
  END IF;

  -- 9. Post Balanced Double-Entry Ledger Transaction
  v_acc_platform_cash := public.ensure_ledger_account(
    'PLATFORM:CASH_CLEARING',
    'Yusr Platform Cash Clearing Account',
    'asset',
    'platform',
    NULL
  );

  IF v_contract.contract_type = 'micro_credit' THEN
    v_acc_user_receivable := public.ensure_ledger_account(
      'USER:' || v_inst.user_id::text || ':QARD_RECEIVABLE',
      'Customer Qard Hasan Receivable',
      'asset',
      'user',
      v_inst.user_id
    );
  ELSE
    v_acc_user_receivable := public.ensure_ledger_account(
      'USER:' || v_inst.user_id::text || ':MURABAHA_RECEIVABLE',
      'Customer Murabaha Receivable',
      'asset',
      'user',
      v_inst.user_id
    );
  END IF;

  v_ledger_meta := jsonb_build_object(
    'user_id', v_inst.user_id::text,
    'installment_id', p_installment_id::text,
    'payment_method', v_pay_method,
    'idempotency_key', v_idem_key
  );

  PERFORM public.post_ledger_entry(
    v_tx_group_id,
    v_inst.user_id::text || ':' || p_installment_id::text || ':' || v_idem_key || ':repay',
    v_acc_platform_cash,
    v_acc_user_receivable,
    v_amount,
    'installment_repayment',
    v_contract.id,
    'Installment #' || v_inst.installment_number || ' repayment via ' || v_pay_method,
    v_ledger_meta
  );

  -- 10. Return Atomic Repayment Result
  RETURN jsonb_build_object(
    'status', 'paid',
    'idempotent_replay', false,
    'installment_id', v_inst.id,
    'contract_id', v_contract.id,
    'user_id', v_inst.user_id,
    'payment_method', v_pay_method,
    'amount_paid', v_amount,
    'principal_replenished', v_principal_replenished,
    'contract_completed', v_contract_completed,
    'account_unfrozen', v_account_unfrozen
  );
END;
$$;

-- Security Hardening: Restrict RPC execution strictly to service_role
REVOKE ALL ON FUNCTION public.process_installment_repayment(UUID, NUMERIC, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_installment_repayment(UUID, NUMERIC, TEXT, TEXT) TO service_role;
