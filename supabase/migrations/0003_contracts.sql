-- ============================================================================
-- Yusr (يُسر) — Migration 0003: Bank Pools, Contracts, Installments & Dunning
-- ============================================================================
-- Depends on: 0001_core_users_kyc.sql, 0002_catalog.sql
-- HARD SHARIA ZERO-RIBA INVARIANTS:
--   1. late_fee_bps MUST ALWAYS EQUAL 0 (enforced via CHECK constraint).
--   2. late_fee_amount MUST ALWAYS EQUAL 0.00 (enforced via CHECK constraint).
--   3. Murabaha requires sequential ownership: Bank purchases asset BEFORE
--      selling to Customer (enforced via customer_accepted_at >= bank_purchased_at).
--   4. Micro-Credit (Qard Hasan) strictly enforces profit_amount = 0.00.
--   5. Fixed total_payable at contract inception (zero variable/compounding APR).
-- ============================================================================

-- 1. Bank Pools Table (Islamic Bank / Institutional Liquidity Sources)
CREATE TABLE public.bank_pools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_code TEXT NOT NULL UNIQUE,
  partner_bank_name TEXT NOT NULL,
  total_capital NUMERIC(14,2) NOT NULL CHECK (total_capital >= 0.00),
  available_liquidity NUMERIC(14,2) NOT NULL CHECK (available_liquidity >= 0.00),
  reserved_liquidity NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (reserved_liquidity >= 0.00),
  -- Fixed Murabaha annual/flat markup rate in basis points (e.g., 800 = 8.00%)
  murabaha_markup_bps INTEGER NOT NULL
    CHECK (murabaha_markup_bps BETWEEN 0 AND 2500),
  -- HARD SHARIA ZERO-RIBA CONSTRAINT
  late_fee_bps INTEGER NOT NULL DEFAULT 0
    CONSTRAINT chk_bank_pools_zero_late_fee CHECK (late_fee_bps = 0),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_pool_liquidity_balance
    CHECK (available_liquidity + reserved_liquidity <= total_capital)
);

CREATE TRIGGER trg_bank_pools_updated_at
  BEFORE UPDATE ON public.bank_pools
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2. Contracts Table (Cash, Qard Hasan Micro-Credit, & Murabaha Contracts)
CREATE TABLE public.contracts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_number TEXT NOT NULL UNIQUE,
  checkout_session_id UUID NOT NULL, -- Groups split-route contracts from one checkout
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  merchant_id UUID NOT NULL REFERENCES public.merchants(id) ON DELETE RESTRICT,
  bank_pool_id UUID REFERENCES public.bank_pools(id) ON DELETE RESTRICT,
  contract_type TEXT NOT NULL
    CHECK (contract_type IN ('cash', 'micro_credit', 'murabaha')),
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN (
      'draft',
      'pending_bank_purchase',
      'bank_owned',
      'murabaha_offered',
      'active',
      'completed',
      'defaulted',
      'cancelled'
    )),
  -- Financial Figures (strict NUMERIC(14,2))
  gross_order_amount NUMERIC(14,2) NOT NULL CHECK (gross_order_amount > 0.00),
  down_payment_amount NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (down_payment_amount >= 0.00),
  financed_principal NUMERIC(14,2) NOT NULL
    CHECK (financed_principal >= 0.00),
  profit_amount NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (profit_amount >= 0.00),
  total_payable NUMERIC(14,2) NOT NULL
    CHECK (total_payable >= financed_principal),
  markup_bps INTEGER NOT NULL DEFAULT 0
    CHECK (markup_bps >= 0),
  -- HARD SHARIA ZERO-RIBA CONSTRAINT: Late penalties are strictly forbidden
  late_fee_bps INTEGER NOT NULL DEFAULT 0
    CONSTRAINT chk_contracts_zero_late_fee CHECK (late_fee_bps = 0),
  tenor_months INTEGER NOT NULL DEFAULT 1
    CHECK (tenor_months BETWEEN 1 AND 36),
  -- Murabaha Ownership Sequence Timestamps (Qabd before Resale)
  bank_purchased_at TIMESTAMPTZ,
  customer_accepted_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Financial Consistency Invariants
  CONSTRAINT chk_contract_principal_split
    CHECK (gross_order_amount = down_payment_amount + financed_principal),
  CONSTRAINT chk_contract_total_payable_formula
    CHECK (total_payable = financed_principal + profit_amount),
  -- Qard Hasan (Micro-Credit) must have zero profit
  CONSTRAINT chk_micro_credit_zero_profit
    CHECK (contract_type <> 'micro_credit' OR (profit_amount = 0.00 AND markup_bps = 0)),
  -- Cash contracts have zero profit and single settlement
  CONSTRAINT chk_cash_contract_terms
    CHECK (contract_type <> 'cash' OR (profit_amount = 0.00 AND markup_bps = 0 AND tenor_months = 1)),
  -- Murabaha contracts require a Bank Pool and valid ownership chronology
  CONSTRAINT chk_murabaha_requires_pool
    CHECK (contract_type <> 'murabaha' OR bank_pool_id IS NOT NULL),
  CONSTRAINT chk_murabaha_ownership_sequence
    CHECK (
      contract_type <> 'murabaha'
      OR customer_accepted_at IS NULL
      OR (bank_purchased_at IS NOT NULL AND customer_accepted_at >= bank_purchased_at)
    )
);

CREATE INDEX idx_contracts_user_status ON public.contracts(user_id, status);
CREATE INDEX idx_contracts_merchant ON public.contracts(merchant_id);
CREATE INDEX idx_contracts_checkout_session ON public.contracts(checkout_session_id);

CREATE TRIGGER trg_contracts_updated_at
  BEFORE UPDATE ON public.contracts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 3. Contract Items Table (Exact line-item snapshot at purchase time)
CREATE TABLE public.contract_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id UUID NOT NULL REFERENCES public.contracts(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  bundle_id UUID REFERENCES public.bundles(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  unit_cost_price NUMERIC(14,2) NOT NULL CHECK (unit_cost_price > 0.00),
  unit_sale_price NUMERIC(14,2) NOT NULL CHECK (unit_sale_price >= unit_cost_price),
  line_total NUMERIC(14,2) NOT NULL CHECK (line_total > 0.00),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_contract_items_contract ON public.contract_items(contract_id);

-- 4. Installments Table (Fixed repayment schedule — Zero Compounding)
CREATE TABLE public.installments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id UUID NOT NULL REFERENCES public.contracts(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  installment_number INTEGER NOT NULL CHECK (installment_number >= 1),
  due_date DATE NOT NULL,
  principal_component NUMERIC(14,2) NOT NULL CHECK (principal_component >= 0.00),
  profit_component NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (profit_component >= 0.00),
  amount_due NUMERIC(14,2) NOT NULL CHECK (amount_due > 0.00),
  amount_paid NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (amount_paid >= 0.00 AND amount_paid <= amount_due),
  -- HARD SHARIA ZERO-RIBA CONSTRAINTS
  late_fee_bps INTEGER NOT NULL DEFAULT 0
    CONSTRAINT chk_installments_zero_late_fee_bps CHECK (late_fee_bps = 0),
  late_fee_amount NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CONSTRAINT chk_installments_zero_late_fee_amount CHECK (late_fee_amount = 0.00),
  status TEXT NOT NULL DEFAULT 'scheduled'
    CHECK (status IN ('scheduled', 'due', 'partial', 'paid', 'overdue', 'rescheduled', 'written_off')),
  dunning_phase INTEGER NOT NULL DEFAULT 0 CHECK (dunning_phase BETWEEN 0 AND 5),
  paid_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (contract_id, installment_number),
  CONSTRAINT chk_installment_components_sum
    CHECK (amount_due = principal_component + profit_component)
);

CREATE INDEX idx_installments_due_status ON public.installments(due_date, status);
CREATE INDEX idx_installments_user_status ON public.installments(user_id, status);

CREATE TRIGGER trg_installments_updated_at
  BEFORE UPDATE ON public.installments
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 5. Dunning Logs Table (5-Phase Sharia-Compliant Ethical Collections Audit)
CREATE TABLE public.dunning_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  installment_id UUID NOT NULL REFERENCES public.installments(id) ON DELETE CASCADE,
  contract_id UUID NOT NULL REFERENCES public.contracts(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  phase INTEGER NOT NULL CHECK (phase BETWEEN 1 AND 5),
  channel TEXT NOT NULL
    CHECK (channel IN ('whatsapp', 'sms', 'push', 'email', 'human_call', 'guarantor_notice')),
  action_taken TEXT NOT NULL,
  delivery_status TEXT NOT NULL DEFAULT 'queued'
    CHECK (delivery_status IN ('queued', 'sent', 'delivered', 'read', 'failed')),
  provider_message_id TEXT,
  notes TEXT,
  executed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_dunning_logs_installment ON public.dunning_logs(installment_id, phase);
CREATE INDEX idx_dunning_logs_user ON public.dunning_logs(user_id, executed_at DESC);

-- 6. Row-Level Security (RLS)
ALTER TABLE public.bank_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contracts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contract_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.installments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dunning_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY contracts_select_own ON public.contracts
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY contract_items_select_own ON public.contract_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.contracts c
      WHERE c.id = contract_items.contract_id
        AND c.user_id = auth.uid()
    )
  );

CREATE POLICY installments_select_own ON public.installments
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY dunning_logs_select_own ON public.dunning_logs
  FOR SELECT USING (auth.uid() = user_id);
