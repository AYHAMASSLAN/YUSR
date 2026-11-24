/**
 * ============================================================================
 * Yusr (يُسر) — Checkout Router Edge Function (Dry-Run & Atomic Confirm)
 * ============================================================================
 * File: supabase/functions/checkout-router/index.ts
 * Runtime: Supabase Edge Functions (Deno / TypeScript)
 *
 * Responsibilities:
 *   1. Authenticate caller via Supabase Auth JWT (never trust body user_id).
 *   2. Validate cart payload, idempotency_key, and confirm flag.
 *   3. Verify caller's KYC status ('verified') and Credit Tier (A, B, C, D).
 *   4. Default (confirm !== true):
 *        Returns deterministic dry_run: true split quote (Cash / Micro-Credit /
 *        per-merchant Murabaha) with zero DB writes.
 *   5. Confirmed (confirm === true):
 *        Ensures active credit_scores snapshot exists, then calls
 *        supabaseAdmin.rpc("execute_checkout_atomic", ...) to atomically lock
 *        limits, deduct stock & bank liquidity, create contracts/installments,
 *        and post balanced double-entry ledger records.
 * ============================================================================
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
import {
  calculateAgeFromDob,
  calculateScore,
  CreditTier,
  getTierPolicy,
  roundCurrency,
  ScoreBreakdown,
  TierPolicy,
} from "../_shared/scoringRules.ts";

// ----------------------------------------------------------------------------
// Types & Interfaces
// ----------------------------------------------------------------------------

interface CartItemRequest {
  product_id: string;
  quantity: number;
  bundle_id?: string | null;
}

interface CheckoutRouterRequest {
  items: CartItemRequest[];
  requested_tenor_months?: number;
  confirm?: boolean;
  idempotency_key?: string;
}

interface DbProduct {
  id: string;
  merchant_id: string;
  name: string;
  unit_price: number | string;
  cost_price: number | string;
  stock_qty: number;
  is_sharia_approved: boolean;
  allows_murabaha: boolean;
  allows_micro_credit: boolean;
  is_active: boolean;
  merchants: {
    id: string;
    business_name: string;
    status: string;
    is_sharia_certified: boolean;
  } | null;
}

interface RoutedLineItem {
  product_id: string;
  merchant_id: string;
  name: string;
  quantity: number;
  unit_price: number;
  line_total: number;
}

interface MurabahaMerchantRoute {
  merchant_id: string;
  merchant_name: string;
  bank_pool_id: string;
  bank_pool_name: string;
  items: RoutedLineItem[];
  gross_amount: number;
  down_payment_amount: number;
  financed_principal: number;
  markup_bps: number;
  profit_amount: number;
  total_payable: number;
  tenor_months: number;
  estimated_monthly_installment: number;
  late_fee_bps: 0; // Hard Sharia zero-riba invariant
}

// ----------------------------------------------------------------------------
// CORS & HTTP Helpers
// ----------------------------------------------------------------------------

function buildCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin");
  const allowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean);

  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };

  if (origin && allowedOrigins.includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }
  return headers;
}

function jsonResponse(
  body: unknown,
  status = 200,
  corsHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

// ----------------------------------------------------------------------------
// Edge Function Handler
// ----------------------------------------------------------------------------

Deno.serve(async (req: Request): Promise<Response> => {
  const corsHeaders = buildCorsHeaders(req);

  // 1. Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse(
      { error: "Method not allowed. Use POST." },
      405,
      corsHeaders,
    );
  }

  // 2. Verify Authorization Header & Bootstrap Scoped Supabase Client
  const authHeader = req.headers.get("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return jsonResponse(
      { error: "Missing or invalid Authorization Bearer token." },
      401,
      corsHeaders,
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceKey) {
    return jsonResponse(
      { error: "Server configuration error: missing Supabase env vars." },
      500,
      corsHeaders,
    );
  }

  // Caller-scoped client (enforces RLS for user/catalog reads and verifies JWT)
  const authClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const {
    data: { user },
    error: authError,
  } = await authClient.auth.getUser();

  if (authError || !user) {
    return jsonResponse(
      { error: "Unauthorized: invalid or expired JWT." },
      401,
      corsHeaders,
    );
  }

  // Service-role client used for internal bank_pools lookup, credit score sync, and atomic RPC
  const supabaseAdmin = createClient(supabaseUrl, supabaseServiceKey);

  // 3. Parse & Validate Request Payload
  let payload: CheckoutRouterRequest;
  try {
    payload = await req.json();
  } catch {
    return jsonResponse(
      { error: "Invalid JSON request body." },
      400,
      corsHeaders,
    );
  }

  if (!Array.isArray(payload.items) || payload.items.length === 0) {
    return jsonResponse(
      { error: "Cart 'items' must be a non-empty array." },
      400,
      corsHeaders,
    );
  }

  if (payload.confirm !== undefined && typeof payload.confirm !== "boolean") {
    return jsonResponse(
      { error: "'confirm' must be a boolean." },
      400,
      corsHeaders,
    );
  }

  if (
    payload.idempotency_key !== undefined &&
    (typeof payload.idempotency_key !== "string" ||
      payload.idempotency_key.trim().length === 0 ||
      payload.idempotency_key.length > 128)
  ) {
    return jsonResponse(
      { error: "'idempotency_key' must be a non-empty string (max 128 chars)." },
      400,
      corsHeaders,
    );
  }

  if (
    payload.requested_tenor_months !== undefined &&
    (typeof payload.requested_tenor_months !== "number" ||
      !Number.isInteger(payload.requested_tenor_months) ||
      payload.requested_tenor_months < 1 ||
      payload.requested_tenor_months > 36)
  ) {
    return jsonResponse(
      { error: "'requested_tenor_months' must be an integer between 1 and 36." },
      400,
      corsHeaders,
    );
  }

  const isConfirmMode = payload.confirm === true;
  const idempotencyKey = payload.idempotency_key?.trim() || crypto.randomUUID();

  // Consolidate duplicate product_ids and validate quantities/UUIDs
  const requestedQtyByProduct = new Map<string, number>();
  for (const item of payload.items) {
    if (
      !item ||
      typeof item.product_id !== "string" ||
      !UUID_REGEX.test(item.product_id)
    ) {
      return jsonResponse(
        { error: "Each cart item must have a valid UUID 'product_id'." },
        400,
        corsHeaders,
      );
    }
    if (
      typeof item.quantity !== "number" ||
      !Number.isInteger(item.quantity) ||
      item.quantity <= 0 ||
      item.quantity > 100
    ) {
      return jsonResponse(
        {
          error: `Invalid quantity for product ${item.product_id}. Must be an integer between 1 and 100.`,
        },
        400,
        corsHeaders,
      );
    }
    requestedQtyByProduct.set(
      item.product_id,
      (requestedQtyByProduct.get(item.product_id) ?? 0) + item.quantity,
    );
  }

  const productIds = Array.from(requestedQtyByProduct.keys());

  // 4. Validate User Account Status & KYC Verification
  const { data: userRecord, error: userErr } = await authClient
    .from("users")
    .select("id, status, role")
    .eq("id", user.id)
    .maybeSingle();

  if (userErr || !userRecord) {
    return jsonResponse(
      { error: "Customer profile not found." },
      404,
      corsHeaders,
    );
  }

  if (userRecord.status !== "active") {
    return jsonResponse(
      {
        error: `Account is currently '${userRecord.status}' and cannot initiate checkout.`,
      },
      403,
      corsHeaders,
    );
  }

  const { data: kycRecord, error: kycErr } = await authClient
    .from("kyc_records")
    .select(
      "status, date_of_birth, verified_monthly_income, has_guarantor, guarantor_verified",
    )
    .eq("user_id", user.id)
    .maybeSingle();

  if (kycErr) {
    return jsonResponse(
      { error: "Failed to verify KYC record." },
      500,
      corsHeaders,
    );
  }

  if (!kycRecord || kycRecord.status !== "verified") {
    return jsonResponse(
      {
        error: "KYC verification is required before using Yusr financing routes.",
        code: "KYC_NOT_VERIFIED",
        kyc_status: kycRecord?.status ?? "unsubmitted",
        allowed_fallback_route: "cash",
      },
      403,
      corsHeaders,
    );
  }

  // 5. Resolve Authoritative Tier & Credit Limits
  const { data: currentScoreRow } = await authClient
    .from("credit_scores")
    .select(
      "score, tier, micro_credit_limit, murabaha_limit, min_down_payment_bps, max_tenor_months, expires_at",
    )
    .eq("user_id", user.id)
    .eq("is_current", true)
    .maybeSingle();

  let activeTier: CreditTier;
  let activeScore: number;
  let policy: TierPolicy;
  let computedBreakdown: ScoreBreakdown | null = null;

  const isScoreValid =
    Boolean(currentScoreRow) &&
    new Date(currentScoreRow!.expires_at).getTime() > Date.now();

  if (isScoreValid && currentScoreRow) {
    activeTier = currentScoreRow.tier as CreditTier;
    activeScore = currentScoreRow.score;
    policy = {
      tier: activeTier,
      microCreditLimit: Number(currentScoreRow.micro_credit_limit),
      murabahaLimit: Number(currentScoreRow.murabaha_limit),
      minDownPaymentBps: currentScoreRow.min_down_payment_bps,
      maxTenorMonths: currentScoreRow.max_tenor_months,
    };
  } else {
    // Fallback: compute deterministic score on the fly from KYC + contract history
    const { data: pastContracts } = await authClient
      .from("contracts")
      .select("id, status")
      .eq("user_id", user.id);

    const { data: pastInstallments } = await authClient
      .from("installments")
      .select("status, paid_at, due_date")
      .eq("user_id", user.id);

    const completedContracts = (pastContracts ?? []).filter(
      (c) => c.status === "completed",
    ).length;
    const hasActiveDefault = (pastContracts ?? []).some(
      (c) => c.status === "defaulted",
    );

    const dueInstallments = (pastInstallments ?? []).filter((i) =>
      ["paid", "overdue", "partial", "due"].includes(i.status),
    );
    const lateInstallments = dueInstallments.filter(
      (i) => i.status === "overdue",
    ).length;
    const onTimeInstallments = dueInstallments.filter(
      (i) =>
        i.status === "paid" &&
        i.paid_at &&
        new Date(i.paid_at) <= new Date(`${i.due_date}T23:59:59Z`),
    ).length;

    const computed = calculateScore({
      monthlyIncome: Number(kycRecord.verified_monthly_income),
      hasGuarantor: Boolean(kycRecord.has_guarantor),
      guarantorVerified: Boolean(kycRecord.guarantor_verified),
      age: calculateAgeFromDob(kycRecord.date_of_birth),
      history: {
        completedContracts,
        onTimeInstallments,
        totalDueInstallments: dueInstallments.length,
        lateInstallments,
        hasActiveDefault,
      },
    });

    activeTier = computed.tier;
    activeScore = computed.score;
    policy = computed.policy;
    computedBreakdown = computed.breakdown;
  }

  // Ensure policy aligns with Tier floor if Tier D
  if (activeTier === "D") {
    policy = getTierPolicy("D");
  }

  // 6. Calculate Outstanding Exposure to Determine Available Credit Headroom
  const { data: openContracts, error: exposureErr } = await authClient
    .from("contracts")
    .select("contract_type, financed_principal, status")
    .eq("user_id", user.id)
    .in("status", [
      "pending_bank_purchase",
      "bank_owned",
      "murabaha_offered",
      "active",
    ]);

  if (exposureErr) {
    return jsonResponse(
      { error: "Failed to check active credit exposure." },
      500,
      corsHeaders,
    );
  }

  let usedMicroCredit = 0;
  let usedMurabaha = 0;
  for (const c of openContracts ?? []) {
    const principal = Number(c.financed_principal);
    if (c.contract_type === "micro_credit") usedMicroCredit += principal;
    if (c.contract_type === "murabaha") usedMurabaha += principal;
  }

  let availableMicroCredit = roundCurrency(
    Math.max(0, policy.microCreditLimit - usedMicroCredit),
  );
  let availableMurabaha = roundCurrency(
    Math.max(0, policy.murabahaLimit - usedMurabaha),
  );

  // 7. Fetch Authoritative Catalog Products & Merchant Status
  const { data: dbProducts, error: prodErr } = await authClient
    .from("products")
    .select(
      `
      id,
      merchant_id,
      name,
      unit_price,
      cost_price,
      stock_qty,
      is_sharia_approved,
      allows_murabaha,
      allows_micro_credit,
      is_active,
      merchants (
        id,
        business_name,
        status,
        is_sharia_certified
      )
    `,
    )
    .in("id", productIds);

  if (prodErr) {
    return jsonResponse(
      { error: "Failed to fetch product catalog." },
      500,
      corsHeaders,
    );
  }

  const productMap = new Map<string, DbProduct>();
  for (const p of (dbProducts ?? []) as unknown as DbProduct[]) {
    productMap.set(p.id, p);
  }

  // Validate every requested product exists, is active, Sharia-approved, and in stock
  for (const [productId, qty] of requestedQtyByProduct.entries()) {
    const product = productMap.get(productId);
    if (!product) {
      return jsonResponse(
        { error: `Product not found: ${productId}` },
        404,
        corsHeaders,
      );
    }
    if (!product.is_active || !product.is_sharia_approved) {
      return jsonResponse(
        {
          error: `Product '${product.name}' is unavailable or not Sharia-approved.`,
        },
        422,
        corsHeaders,
      );
    }
    if (
      !product.merchants ||
      product.merchants.status !== "active" ||
      !product.merchants.is_sharia_certified
    ) {
      return jsonResponse(
        {
          error: `Merchant for '${product.name}' is inactive or uncertified.`,
        },
        422,
        corsHeaders,
      );
    }
    if (product.stock_qty < qty) {
      return jsonResponse(
        {
          error: `Insufficient stock for '${product.name}'. Requested ${qty}, available ${product.stock_qty}.`,
        },
        422,
        corsHeaders,
      );
    }
  }

  // 8. Fetch Best Active Islamic Bank Liquidity Pool for Murabaha Quote
  const { data: activePools, error: poolErr } = await supabaseAdmin
    .from("bank_pools")
    .select("id, partner_bank_name, available_liquidity, murabaha_markup_bps, late_fee_bps")
    .eq("is_active", true)
    .gt("available_liquidity", 0)
    .order("murabaha_markup_bps", { ascending: true })
    .order("id", { ascending: true })
    .limit(1);

  if (poolErr) {
    return jsonResponse(
      { error: "Failed to query Islamic bank liquidity pools." },
      500,
      corsHeaders,
    );
  }

  const selectedPool = activePools && activePools.length > 0 ? activePools[0] : null;
  let availablePoolLiquidity = selectedPool
    ? roundCurrency(Number(selectedPool.available_liquidity))
    : 0;

  // Determine requested tenor bounded by Tier policy
  const requestedTenor =
    typeof payload.requested_tenor_months === "number" &&
    Number.isInteger(payload.requested_tenor_months)
      ? Math.max(1, Math.min(payload.requested_tenor_months, policy.maxTenorMonths))
      : policy.maxTenorMonths;

  // Sort cart items deterministically by product_id ASC to match execute_checkout_atomic
  const sortedCartEntries = Array.from(requestedQtyByProduct.entries()).sort(
    ([a], [b]) => (a < b ? -1 : a > b ? 1 : 0),
  );

  // 8b. Confirmed Execution Branch (confirm: true -> Atomic PostgreSQL RPC)
  if (isConfirmMode) {
    // Persist freshly calculated credit_scores snapshot if missing or expired
    // so execute_checkout_atomic locks the exact same Tier & limits.
    if (!isScoreValid && computedBreakdown) {
      await supabaseAdmin
        .from("credit_scores")
        .update({ is_current: false })
        .eq("user_id", user.id)
        .eq("is_current", true);

      const { error: scoreInsertErr } = await supabaseAdmin
        .from("credit_scores")
        .insert({
          user_id: user.id,
          score: activeScore,
          tier: activeTier,
          micro_credit_limit: policy.microCreditLimit,
          murabaha_limit: policy.murabahaLimit,
          min_down_payment_bps: policy.minDownPaymentBps,
          max_tenor_months: policy.maxTenorMonths,
          score_breakdown: computedBreakdown,
          is_current: true,
        });

      if (scoreInsertErr) {
        return jsonResponse(
          { error: "Failed to persist underwriting score snapshot." },
          500,
          corsHeaders,
        );
      }
    }

    const rpcPayload = {
      idempotency_key: idempotencyKey,
      requested_tenor_months: requestedTenor,
      items: sortedCartEntries.map(([product_id, quantity]) => ({
        product_id,
        quantity,
      })),
    };

    const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc(
      "execute_checkout_atomic",
      {
        p_user_id: user.id,
        p_payload: rpcPayload,
      },
    );

    if (rpcError) {
      const msg = rpcError.message ?? "Atomic checkout failed.";
      const statusCode = msg.includes("KYC_NOT_VERIFIED") ||
          msg.includes("ACCOUNT_RESTRICTED")
        ? 403
        : msg.includes("PRODUCT_NOT_FOUND") || msg.includes("USER_NOT_FOUND")
        ? 404
        : msg.includes("INSUFFICIENT_STOCK") ||
            msg.includes("MERCHANT_INACTIVE") ||
            msg.includes("SHARIA_OR_CATALOG_ERROR")
        ? 409
        : 422;

      return jsonResponse(
        {
          dry_run: false,
          confirmed: false,
          error: msg,
        },
        statusCode,
        corsHeaders,
      );
    }

    const isReplay = Boolean(
      rpcResult &&
        typeof rpcResult === "object" &&
        "idempotent_replay" in rpcResult &&
        rpcResult.idempotent_replay,
    );

    return jsonResponse(
      {
        dry_run: false,
        ...(rpcResult as Record<string, unknown>),
      },
      isReplay ? 200 : 201,
      corsHeaders,
    );
  }

  // 9. Deterministic Split-Routing Preview Engine (confirm !== true -> dry_run: true)
  const cashItems: RoutedLineItem[] = [];
  const microCreditItems: RoutedLineItem[] = [];
  const murabahaByMerchant = new Map<
    string,
    { merchantName: string; items: RoutedLineItem[]; grossAmount: number }
  >();

  let cartGrandTotal = 0;
  let cashTotal = 0;
  let microCreditTotal = 0;

  for (const [productId, qty] of sortedCartEntries) {
    const product = productMap.get(productId)!;
    const unitPrice = roundCurrency(Number(product.unit_price));
    const lineTotal = roundCurrency(unitPrice * qty);
    cartGrandTotal = roundCurrency(cartGrandTotal + lineTotal);

    const lineItem: RoutedLineItem = {
      product_id: product.id,
      merchant_id: product.merchant_id,
      name: product.name,
      quantity: qty,
      unit_price: unitPrice,
      line_total: lineTotal,
    };

    // Route Priority 1: Micro-Credit (Qard Hasan, 0% profit) for eligible small items
    // if user has Tier headroom (A/B/C) and product allows micro-credit.
    if (
      activeTier !== "D" &&
      product.allows_micro_credit &&
      availableMicroCredit >= lineTotal
    ) {
      microCreditItems.push(lineItem);
      microCreditTotal = roundCurrency(microCreditTotal + lineTotal);
      availableMicroCredit = roundCurrency(availableMicroCredit - lineTotal);
      continue;
    }

    // Route Priority 2: Murabaha (Cost-Plus) if eligible, Tier allows, and Bank Pool has liquidity
    const minDownRatio = policy.minDownPaymentBps / 10000;
    const requiredDownPayment = roundCurrency(lineTotal * minDownRatio);
    const requiredFinancedPrincipal = roundCurrency(lineTotal - requiredDownPayment);

    if (
      activeTier !== "D" &&
      product.allows_murabaha &&
      selectedPool !== null &&
      requestedTenor >= 1 &&
      availableMurabaha >= requiredFinancedPrincipal &&
      availablePoolLiquidity >= requiredFinancedPrincipal
    ) {
      availableMurabaha = roundCurrency(availableMurabaha - requiredFinancedPrincipal);
      availablePoolLiquidity = roundCurrency(
        availablePoolLiquidity - requiredFinancedPrincipal,
      );

      const existingGroup = murabahaByMerchant.get(product.merchant_id);
      if (existingGroup) {
        existingGroup.items.push(lineItem);
        existingGroup.grossAmount = roundCurrency(
          existingGroup.grossAmount + lineTotal,
        );
      } else {
        murabahaByMerchant.set(product.merchant_id, {
          merchantName: product.merchants!.business_name,
          items: [lineItem],
          grossAmount: lineTotal,
        });
      }
      continue;
    }

    // Route Priority 3 (Fallback): Cash Checkout
    cashItems.push(lineItem);
    cashTotal = roundCurrency(cashTotal + lineTotal);
  }

  // Build Per-Merchant Murabaha Contract Previews (Sharia requires 1 contract per Merchant asset sale)
  const murabahaContracts: MurabahaMerchantRoute[] = [];
  let murabahaTotalDownPayment = 0;
  let murabahaTotalPrincipal = 0;
  let murabahaTotalProfit = 0;

  for (const [merchantId, group] of murabahaByMerchant.entries()) {
    const downPayment = roundCurrency(
      group.grossAmount * (policy.minDownPaymentBps / 10000),
    );
    const financedPrincipal = roundCurrency(group.grossAmount - downPayment);
    const markupBps = selectedPool!.murabaha_markup_bps;

    // Pro-rata fixed flat Murabaha profit for requested tenor (zero compounding)
    const profitAmount = roundCurrency(
      financedPrincipal * (markupBps / 10000) * (requestedTenor / 12),
    );
    const totalPayable = roundCurrency(financedPrincipal + profitAmount);
    const monthlyInstallment = roundCurrency(totalPayable / requestedTenor);

    murabahaTotalDownPayment = roundCurrency(murabahaTotalDownPayment + downPayment);
    murabahaTotalPrincipal = roundCurrency(
      murabahaTotalPrincipal + financedPrincipal,
    );
    murabahaTotalProfit = roundCurrency(murabahaTotalProfit + profitAmount);

    murabahaContracts.push({
      merchant_id: merchantId,
      merchant_name: group.merchantName,
      bank_pool_id: selectedPool!.id,
      bank_pool_name: selectedPool!.partner_bank_name,
      items: group.items,
      gross_amount: group.grossAmount,
      down_payment_amount: downPayment,
      financed_principal: financedPrincipal,
      markup_bps: markupBps,
      profit_amount: profitAmount,
      total_payable: totalPayable,
      tenor_months: requestedTenor,
      estimated_monthly_installment: monthlyInstallment,
      late_fee_bps: 0,
    });
  }

  // Total immediate cash due at checkout = Cash-only items + Murabaha down payments
  const totalDueNowCash = roundCurrency(cashTotal + murabahaTotalDownPayment);

  // 10. Return Dry-Run Quote (Zero DB Writes)
  return jsonResponse(
    {
      dry_run: true,
      quote_id: crypto.randomUUID(),
      user_underwriting: {
        user_id: user.id,
        kyc_status: kycRecord.status,
        credit_score: activeScore,
        tier: activeTier,
        limits: {
          micro_credit_limit: policy.microCreditLimit,
          murabaha_limit: policy.murabahaLimit,
          remaining_micro_credit_before_checkout: roundCurrency(
            Math.max(0, policy.microCreditLimit - usedMicroCredit),
          ),
          remaining_murabaha_before_checkout: roundCurrency(
            Math.max(0, policy.murabahaLimit - usedMurabaha),
          ),
        },
      },
      summary: {
        cart_grand_total: cartGrandTotal,
        due_now_cash_total: totalDueNowCash,
        micro_credit_financed_total: microCreditTotal,
        murabaha_financed_principal_total: murabahaTotalPrincipal,
        murabaha_fixed_profit_total: murabahaTotalProfit,
      },
      routes: {
        cash: {
          items: cashItems,
          cash_items_subtotal: cashTotal,
          murabaha_down_payments_total: murabahaTotalDownPayment,
          total_due_now: totalDueNowCash,
        },
        micro_credit: {
          contract_type: "qard_hasan",
          profit_amount: 0.0,
          late_fee_bps: 0,
          items: microCreditItems,
          financed_principal: microCreditTotal,
        },
        murabaha: {
          contracts_by_merchant: murabahaContracts,
          total_financed_principal: murabahaTotalPrincipal,
          total_fixed_profit: murabahaTotalProfit,
          late_fee_bps: 0,
        },
      },
      sharia_compliance: {
        zero_riba_verified: true,
        late_fee_bps: 0,
        compounding_interest: false,
        murabaha_grouped_by_merchant: true,
      },
    },
    200,
    corsHeaders,
  );
});
