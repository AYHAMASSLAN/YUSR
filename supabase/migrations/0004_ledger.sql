-- ============================================================================
-- Yusr (يُسر) — Migration 0004: Double-Entry Immutable Financial Ledger
-- ============================================================================
-- Depends on: 0003_contracts.sql
-- Architecture Invariants:
--   1. Append-only double-entry bookkeeping (UPDATE and DELETE are blocked).
--   2. Every transaction row pairs distinct debit and credit accounts.
--   3. Idempotency key prevents duplicate postings on network retries.
--   4. Strict NUMERIC(14,2) for all balances and transaction amounts.
-- ============================================================================

-- 1. Ledger Accounts Table (Chart of Accounts)
CREATE TABLE public.ledger_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_code TEXT NOT NULL UNIQUE,
  account_name TEXT NOT NULL,
  account_type TEXT NOT NULL
    CHECK (account_type IN ('asset', 'liability', 'equity', 'revenue', 'expense')),
  owner_type TEXT NOT NULL
    CHECK (owner_type IN ('platform', 'user', 'merchant', 'bank_pool', 'charity_box')),
  owner_id UUID, -- References users.id, merchants.id, or bank_pools.id depending on owner_type
  currency CHAR(3) NOT NULL DEFAULT 'SAR',
  balance NUMERIC(14,2) NOT NULL DEFAULT 0.00,
  is_frozen BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_ledger_accounts_owner ON public.ledger_accounts(owner_type, owner_id);

CREATE TRIGGER trg_ledger_accounts_updated_at
  BEFORE UPDATE ON public.ledger_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2. Ledger Transactions Table (Immutable Double-Entry Journal)
CREATE TABLE public.ledger_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Groups balanced multi-leg postings belonging to a single business event
  transaction_group_id UUID NOT NULL,
  idempotency_key TEXT NOT NULL,
  debit_account_id UUID NOT NULL REFERENCES public.ledger_accounts(id) ON DELETE RESTRICT,
  credit_account_id UUID NOT NULL REFERENCES public.ledger_accounts(id) ON DELETE RESTRICT,
  amount NUMERIC(14,2) NOT NULL CHECK (amount > 0.00),
  currency CHAR(3) NOT NULL DEFAULT 'SAR',
  entry_type TEXT NOT NULL CHECK (entry_type IN (
    'cash_settlement',
    'down_payment',
    'bank_asset_purchase',
    'murabaha_sale_booking',
    'murabaha_profit_booking',
    'micro_credit_disbursement',
    'installment_repayment',
    'merchant_payout',
    'platform_agency_fee',
    'refund_reversal'
  )),
  contract_id UUID REFERENCES public.contracts(id) ON DELETE RESTRICT,
  installment_id UUID REFERENCES public.installments(id) ON DELETE RESTRICT,
  description TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Prevent self-transfer entries and duplicate idempotent retries
  CONSTRAINT chk_distinct_debit_credit CHECK (debit_account_id <> credit_account_id),
  CONSTRAINT uq_ledger_idempotency UNIQUE (idempotency_key, debit_account_id, credit_account_id)
);

CREATE INDEX idx_ledger_tx_group ON public.ledger_transactions(transaction_group_id);
CREATE INDEX idx_ledger_tx_contract ON public.ledger_transactions(contract_id);
CREATE INDEX idx_ledger_tx_debit ON public.ledger_transactions(debit_account_id, created_at DESC);
CREATE INDEX idx_ledger_tx_credit ON public.ledger_transactions(credit_account_id, created_at DESC);

-- 3. Immutability Guard: Append-Only Ledger Enforcement
-- Financial corrections MUST be posted as compensating reversal entries, never mutated in place.
CREATE OR REPLACE FUNCTION public.prevent_ledger_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'ledger_transactions is append-only; UPDATE and DELETE are prohibited (use refund_reversal entry instead).';
END;
$$;

CREATE TRIGGER trg_ledger_transactions_immutable
  BEFORE UPDATE OR DELETE ON public.ledger_transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_ledger_mutation();

-- 4. Row-Level Security (RLS)
-- Ledger tables are written exclusively by SECURITY DEFINER RPCs / service_role.
ALTER TABLE public.ledger_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY ledger_accounts_select_own ON public.ledger_accounts
  FOR SELECT USING (owner_type = 'user' AND owner_id = auth.uid());

CREATE POLICY ledger_tx_select_own ON public.ledger_transactions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.ledger_accounts la
      WHERE (la.id = ledger_transactions.debit_account_id OR la.id = ledger_transactions.credit_account_id)
        AND la.owner_type = 'user'
        AND la.owner_id = auth.uid()
    )
  );
