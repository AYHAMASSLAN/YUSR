-- ============================================================================
-- Yusr (يُسر) — Migration 0001: Core Users, KYC Records & Credit Scoring
-- ============================================================================
-- Target: Supabase PostgreSQL (15+)
-- Sharia Invariants:
--   1. All monetary fields strictly use NUMERIC(14,2) (never FLOAT/DOUBLE).
--   2. Deterministic Credit Tiering (A, B, C, D) stored with audit trail.
--   3. Row-Level Security (RLS) enabled on all user-facing tables.
-- ============================================================================

-- 1. Required Extensions
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. Shared Trigger Function for automatic updated_at timestamps
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- 3. Users Table (mirrors and extends Supabase auth.users)
CREATE TABLE public.users (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL CHECK (char_length(trim(full_name)) >= 2),
  phone_number TEXT NOT NULL UNIQUE,
  email TEXT UNIQUE,
  role TEXT NOT NULL DEFAULT 'customer'
    CHECK (role IN ('customer', 'merchant', 'admin', 'bank_auditor')),
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'frozen', 'suspended', 'closed')),
  preferred_locale TEXT NOT NULL DEFAULT 'ar'
    CHECK (preferred_locale IN ('ar', 'en')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_users_role ON public.users(role);
CREATE INDEX idx_users_status ON public.users(status);

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 4. KYC Records Table (Identity, Income, Age, & Guarantor Verification)
CREATE TABLE public.kyc_records (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  national_id_hash TEXT NOT NULL UNIQUE,
  date_of_birth DATE NOT NULL,
  -- Verified monthly net income in base currency (strict NUMERIC(14,2))
  declared_monthly_income NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (declared_monthly_income >= 0.00),
  verified_monthly_income NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (verified_monthly_income >= 0.00),
  employment_status TEXT NOT NULL DEFAULT 'employed'
    CHECK (employment_status IN ('employed', 'self_employed', 'student', 'retired', 'unemployed')),
  -- Guarantor details (supports Tier uplift without riba collateral)
  has_guarantor BOOLEAN NOT NULL DEFAULT false,
  guarantor_name TEXT,
  guarantor_phone TEXT,
  guarantor_national_id_hash TEXT,
  guarantor_verified BOOLEAN NOT NULL DEFAULT false,
  -- Verification workflow
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'in_review', 'verified', 'rejected', 'expired')),
  rejection_reason TEXT,
  verified_by UUID REFERENCES public.users(id),
  verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Enforce guarantor completeness when guarantor is marked verified
  CONSTRAINT chk_guarantor_verified_requires_flag
    CHECK (NOT guarantor_verified OR (has_guarantor AND guarantor_name IS NOT NULL AND guarantor_phone IS NOT NULL))
);

CREATE INDEX idx_kyc_records_status ON public.kyc_records(status);

CREATE TRIGGER trg_kyc_records_updated_at
  BEFORE UPDATE ON public.kyc_records
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 5. Credit Scores Table (Deterministic 0-100 Score & Tier A/B/C/D Snapshot)
CREATE TABLE public.credit_scores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  score INTEGER NOT NULL CHECK (score BETWEEN 0 AND 100),
  tier CHAR(1) NOT NULL CHECK (tier IN ('A', 'B', 'C', 'D')),
  -- Financing ceilings in NUMERIC(14,2)
  micro_credit_limit NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (micro_credit_limit >= 0.00),
  murabaha_limit NUMERIC(14,2) NOT NULL DEFAULT 0.00
    CHECK (murabaha_limit >= 0.00),
  min_down_payment_bps INTEGER NOT NULL DEFAULT 10000
    CHECK (min_down_payment_bps BETWEEN 0 AND 10000),
  max_tenor_months INTEGER NOT NULL DEFAULT 1
    CHECK (max_tenor_months BETWEEN 1 AND 36),
  -- Audit breakdown of scoring components (income, guarantor, age, history)
  score_breakdown JSONB NOT NULL DEFAULT '{}'::jsonb,
  scoring_version TEXT NOT NULL DEFAULT 'v1.0.0',
  is_current BOOLEAN NOT NULL DEFAULT true,
  calculated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '90 days')
);

-- Ensure at most one active current score per user
CREATE UNIQUE INDEX idx_credit_scores_one_current_per_user
  ON public.credit_scores(user_id)
  WHERE is_current = true;

CREATE INDEX idx_credit_scores_user_history
  ON public.credit_scores(user_id, calculated_at DESC);

-- 6. Row-Level Security (RLS)
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kyc_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_scores ENABLE ROW LEVEL SECURITY;

CREATE POLICY users_select_own ON public.users
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY kyc_select_own ON public.kyc_records
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY credit_scores_select_own ON public.credit_scores
  FOR SELECT USING (auth.uid() = user_id);
