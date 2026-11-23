-- ============================================================================
-- Yusr (يُسر) — Migration 0002: Merchant & Sharia-Compliant Catalog
-- ============================================================================
-- Depends on: 0001_core_users_kyc.sql
-- Sharia Invariants:
--   1. Merchants & products carry explicit Sharia approval flags.
--   2. Intangible/speculative or prohibited goods cannot use Murabaha.
--   3. All prices and commissions use strict NUMERIC(14,2) or basis points.
-- ============================================================================

-- 1. Merchants Table
CREATE TABLE public.merchants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  business_name TEXT NOT NULL CHECK (char_length(trim(business_name)) >= 2),
  commercial_registration_no TEXT NOT NULL UNIQUE,
  category TEXT NOT NULL,
  -- Platform merchant discount / agency fee in basis points (e.g. 250 = 2.50%)
  commission_bps INTEGER NOT NULL DEFAULT 250
    CHECK (commission_bps BETWEEN 0 AND 3000),
  settlement_iban TEXT NOT NULL,
  is_sharia_certified BOOLEAN NOT NULL DEFAULT true,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'active', 'suspended', 'offboarded')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_merchants_owner ON public.merchants(owner_user_id);
CREATE INDEX idx_merchants_status ON public.merchants(status);

CREATE TRIGGER trg_merchants_updated_at
  BEFORE UPDATE ON public.merchants
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2. Products Table
CREATE TABLE public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.merchants(id) ON DELETE CASCADE,
  sku TEXT NOT NULL,
  name TEXT NOT NULL CHECK (char_length(trim(name)) >= 2),
  description TEXT,
  category TEXT NOT NULL,
  -- Authoritative catalog unit price (strict NUMERIC(14,2))
  unit_price NUMERIC(14,2) NOT NULL CHECK (unit_price > 0.00),
  -- Wholesale/cost price paid by Bank Pool in Murabaha (<= unit_price)
  cost_price NUMERIC(14,2) NOT NULL CHECK (cost_price > 0.00),
  stock_qty INTEGER NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),
  -- Sharia & financing eligibility flags
  is_sharia_approved BOOLEAN NOT NULL DEFAULT true,
  allows_murabaha BOOLEAN NOT NULL DEFAULT true,
  allows_micro_credit BOOLEAN NOT NULL DEFAULT true,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (merchant_id, sku),
  CONSTRAINT chk_product_cost_le_unit_price CHECK (cost_price <= unit_price),
  CONSTRAINT chk_sharia_required_for_financing
    CHECK (is_sharia_approved OR (NOT allows_murabaha AND NOT allows_micro_credit))
);

CREATE INDEX idx_products_merchant_active ON public.products(merchant_id, is_active);

CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 3. Bundles Table (Curated multi-product kits / packages)
CREATE TABLE public.bundles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  merchant_id UUID NOT NULL REFERENCES public.merchants(id) ON DELETE CASCADE,
  title TEXT NOT NULL CHECK (char_length(trim(title)) >= 2),
  description TEXT,
  bundle_price NUMERIC(14,2) NOT NULL CHECK (bundle_price > 0.00),
  is_sharia_approved BOOLEAN NOT NULL DEFAULT true,
  allows_murabaha BOOLEAN NOT NULL DEFAULT true,
  allows_micro_credit BOOLEAN NOT NULL DEFAULT true,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_bundle_sharia_required
    CHECK (is_sharia_approved OR (NOT allows_murabaha AND NOT allows_micro_credit))
);

CREATE INDEX idx_bundles_merchant_active ON public.bundles(merchant_id, is_active);

CREATE TRIGGER trg_bundles_updated_at
  BEFORE UPDATE ON public.bundles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 4. Bundle Items Table (Join table between bundles and products)
CREATE TABLE public.bundle_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bundle_id UUID NOT NULL REFERENCES public.bundles(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (bundle_id, product_id)
);

CREATE INDEX idx_bundle_items_product ON public.bundle_items(product_id);

-- 5. Row-Level Security (RLS)
ALTER TABLE public.merchants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bundles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bundle_items ENABLE ROW LEVEL SECURITY;

-- Active catalog items are publicly readable to authenticated shoppers
CREATE POLICY merchants_select_active ON public.merchants
  FOR SELECT USING (status = 'active');

CREATE POLICY products_select_active ON public.products
  FOR SELECT USING (is_active = true AND is_sharia_approved = true);

CREATE POLICY bundles_select_active ON public.bundles
  FOR SELECT USING (is_active = true AND is_sharia_approved = true);

CREATE POLICY bundle_items_select_all ON public.bundle_items
  FOR SELECT USING (true);
