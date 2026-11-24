/**
 * ============================================================================
 * Yusr (يُسر) — Repayment Processor & Dynamic Credit Upgrade Edge Function
 * ============================================================================
 * File: supabase/functions/repayment-processor/index.ts
 * Self-contained for direct deployment from the Supabase Dashboard editor.
 * ============================================================================
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

// ----------------------------------------------------------------------------
// Embedded Deterministic Scoring Rules (Self-Contained)
// ----------------------------------------------------------------------------

type CreditTier = "A" | "B" | "C" | "D";

interface ScoringInput {
  monthlyIncome: number;
  hasGuarantor: boolean;
  guarantorVerified: boolean;
  age: number;
  history: {
    completedContracts: number;
    onTimeInstallments: number;
    totalDueInstallments: number;
    lateInstallments: number;
    hasActiveDefault: boolean;
  };
}

interface TierPolicy {
  tier: CreditTier;
  microCreditLimit: number;
  murabahaLimit: number;
  minDownPaymentBps: number;
  maxTenorMonths: number;
}

const TIER_RANK: Record<CreditTier, number> = { D: 0, C: 1, B: 2, A: 3 };

function clamp(v: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, v));
}

function calculateAgeFromDob(dobStr: string, ref = new Date()): number {
  const dob = new Date(dobStr);
  if (Number.isNaN(dob.getTime())) return 0;
  let age = ref.getUTCFullYear() - dob.getUTCFullYear();
  const m = ref.getUTCMonth() - dob.getUTCMonth();
  if (m < 0 || (m === 0 && ref.getUTCDate() < dob.getUTCDate())) age -= 1;
  return Math.max(0, age);
}

function getTierPolicy(tier: CreditTier): TierPolicy {
  switch (tier) {
    case "A":
      return { tier: "A", microCreditLimit: 2000, murabahaLimit: 25000, minDownPaymentBps: 1000, maxTenorMonths: 12 };
    case "B":
      return { tier: "B", microCreditLimit: 1000, murabahaLimit: 12000, minDownPaymentBps: 1500, maxTenorMonths: 9 };
    case "C":
      return { tier: "C", microCreditLimit: 500, murabahaLimit: 4000, minDownPaymentBps: 2500, maxTenorMonths: 6 };
    default:
      return { tier: "D", microCreditLimit: 0, murabahaLimit: 0, minDownPaymentBps: 10000, maxTenorMonths: 1 };
  }
}

function calculateScore(input: ScoringInput) {
  const income = input.monthlyIncome <= 0 ? 0
    : input.monthlyIncome < 1500 ? 5
    : input.monthlyIncome < 3000 ? 12
    : input.monthlyIncome < 6000 ? 20
    : input.monthlyIncome < 10000 ? 28
    : 35;

  const guarantor = input.hasGuarantor && input.guarantorVerified ? 15
    : input.hasGuarantor ? 5 : 0;

  const agePts = input.age < 18 ? 0
    : input.age <= 21 ? 6
    : input.age <= 25 ? 10
    : input.age <= 55 ? 15
    : input.age <= 65 ? 11 : 7;

  let historyPts = 15;
  if (input.history.hasActiveDefault) {
    historyPts = 0;
  } else if (input.history.completedContracts > 0 || input.history.totalDueInstallments > 0 || input.history.lateInstallments > 0) {
    const contractBonus = Math.min(12, Math.max(0, input.history.completedContracts) * 4);
    const ratio = input.history.totalDueInstallments > 0
      ? clamp(input.history.onTimeInstallments, 0, input.history.totalDueInstallments) / input.history.totalDueInstallments
      : 1;
    historyPts = clamp(15 + contractBonus + Math.round(ratio * 8) - Math.max(0, input.history.lateInstallments) * 5, 0, 35);
  }

  const raw = clamp(Math.round(income + guarantor + agePts + historyPts), 0, 100);
  const hardOverrideReason = input.age < 18
    ? "APPLICANT_UNDER_18"
    : input.history.hasActiveDefault
    ? "ACTIVE_DEFAULT_DETECTED"
    : null;

  const score = hardOverrideReason ? Math.min(raw, 39) : raw;
  const tier: CreditTier = hardOverrideReason
    ? "D"
    : score >= 80 ? "A"
    : score >= 60 ? "B"
    : score >= 40 ? "C" : "D";

  return {
    score,
    tier,
    breakdown: { incomePoints: income, historyPoints: historyPts, guarantorPoints: guarantor, agePoints: agePts, hardOverrideReason },
    policy: getTierPolicy(tier),
  };
}

// ----------------------------------------------------------------------------
// HTTP & Security Helpers
// ----------------------------------------------------------------------------

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_METHODS = new Set(["sham_cash", "bank_transfer", "cash_agent"]);

function buildCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin");
  const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && allowed.includes(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "Content-Type": "application/json; charset=utf-8" },
  });
}

// ----------------------------------------------------------------------------
// Edge Function Entry Point
// ----------------------------------------------------------------------------

Deno.serve(async (req: Request): Promise<Response> => {
  const cors = buildCorsHeaders(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed. Use POST." }, 405, cors);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "Missing or invalid Authorization Bearer token." }, 401, cors);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceKey) {
    return json({ error: "Missing Supabase environment variables." }, 500, cors);
  }

  // 1. Authenticate caller (Customer, Cash Agent, or Admin)
  const authClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authErr } = await authClient.auth.getUser();
  if (authErr || !user) return json({ error: "Unauthorized: invalid or expired JWT." }, 401, cors);

  const supabaseAdmin = createClient(supabaseUrl, supabaseServiceKey);

  // 2. Validate Request Body
  let body: {
    installment_id?: string;
    amount?: number;
    payment_method?: string;
    idempotency_key?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body." }, 400, cors);
  }

  const installmentId = body.installment_id;
  const amount = body.amount;
  const paymentMethod = body.payment_method?.trim().toLowerCase();
  const idempotencyKey = body.idempotency_key?.trim() || crypto.randomUUID();

  if (!installmentId || !UUID_REGEX.test(installmentId)) {
    return json({ error: "Valid UUID 'installment_id' is required." }, 400, cors);
  }
  if (typeof amount !== "number" || !Number.isFinite(amount) || amount <= 0) {
    return json({ error: "'amount' must be a positive number." }, 400, cors);
  }
  if (!paymentMethod || !ALLOWED_METHODS.has(paymentMethod)) {
    return json({ error: "'payment_method' must be sham_cash, bank_transfer, or cash_agent." }, 400, cors);
  }

  // 3. Enforce Caller Authorization (Admin can process any; Customers only their own)
  const [{ data: callerProfile }, { data: targetInstallment }] = await Promise.all([
    supabaseAdmin.from("users").select("role").eq("id", user.id).maybeSingle(),
    supabaseAdmin.from("installments").select("id, user_id").eq("id", installmentId).maybeSingle(),
  ]);

  if (!targetInstallment) return json({ error: "Installment not found." }, 404, cors);

  const isPrivileged = callerProfile?.role === "admin";
  if (!isPrivileged && targetInstallment.user_id !== user.id) {
    return json({ error: "Forbidden: you cannot process repayments for another customer." }, 403, cors);
  }

  const targetUserId = targetInstallment.user_id;

  // Capture previous credit score & tier before recalculation
  const { data: prevScoreRow } = await supabaseAdmin
    .from("credit_scores")
    .select("score, tier")
    .eq("user_id", targetUserId)
    .eq("is_current", true)
    .maybeSingle();

  const previousTier = (prevScoreRow?.tier as CreditTier | undefined) ?? "D";
  const previousScore = prevScoreRow?.score ?? 0;

  // 4. Execute Atomic PostgreSQL Repayment RPC
  const { data: rpcResult, error: rpcError } = await supabaseAdmin.rpc(
    "process_installment_repayment",
    {
      p_installment_id: installmentId,
      p_amount: amount,
      p_payment_method: paymentMethod,
      p_idempotency_key: idempotencyKey,
    },
  );

  if (rpcError) {
    const msg = rpcError.message ?? "Repayment failed.";
    const status = msg.includes("NOT_FOUND") ? 404
      : msg.includes("ALREADY_PAID") || msg.includes("INVALID_INSTALLMENT_STATE") ? 409
      : 422;
    return json({ error: msg }, status, cors);
  }

  // 5. Recalculate Dynamic Credit Score & Upgrade Tier if Eligible
  const [{ data: kyc }, { data: contracts }, { data: installments }] = await Promise.all([
    supabaseAdmin
      .from("kyc_records")
      .select("date_of_birth, verified_monthly_income, has_guarantor, guarantor_verified")
      .eq("user_id", targetUserId)
      .maybeSingle(),
    supabaseAdmin.from("contracts").select("status").eq("user_id", targetUserId),
    supabaseAdmin.from("installments").select("status, paid_at, due_date").eq("user_id", targetUserId),
  ]);

  const completedContracts = (contracts ?? []).filter((c) => c.status === "completed").length;
  const hasActiveDefault = (contracts ?? []).some((c) => c.status === "defaulted");
  const dueInst = (installments ?? []).filter((i) => ["paid", "overdue", "partial", "due"].includes(i.status));
  const lateInstallments = dueInst.filter((i) => i.status === "overdue").length;
  const onTimeInstallments = dueInst.filter(
    (i) => i.status === "paid" && i.paid_at && new Date(i.paid_at) <= new Date(`${i.due_date}T23:59:59Z`),
  ).length;

  const updated = calculateScore({
    monthlyIncome: Number(kyc?.verified_monthly_income ?? 0),
    hasGuarantor: Boolean(kyc?.has_guarantor),
    guarantorVerified: Boolean(kyc?.guarantor_verified),
    age: kyc?.date_of_birth ? calculateAgeFromDob(kyc.date_of_birth) : 0,
    history: {
      completedContracts,
      onTimeInstallments,
      totalDueInstallments: dueInst.length,
      lateInstallments,
      hasActiveDefault,
    },
  });

  // Persist refreshed credit_scores snapshot (is_current = true)
  if (updated.score !== previousScore || updated.tier !== previousTier || !prevScoreRow) {
    await supabaseAdmin
      .from("credit_scores")
      .update({ is_current: false })
      .eq("user_id", targetUserId)
      .eq("is_current", true);

    await supabaseAdmin.from("credit_scores").insert({
      user_id: targetUserId,
      score: updated.score,
      tier: updated.tier,
      micro_credit_limit: updated.policy.microCreditLimit,
      murabaha_limit: updated.policy.murabahaLimit,
      min_down_payment_bps: updated.policy.minDownPaymentBps,
      max_tenor_months: updated.policy.maxTenorMonths,
      score_breakdown: updated.breakdown,
      is_current: true,
    });
  }

  const tierUpgraded = TIER_RANK[updated.tier] > TIER_RANK[previousTier];
  const rpcObj = (rpcResult ?? {}) as Record<string, unknown>;

  return json(
    {
      status: "paid",
      idempotent_replay: Boolean(rpcObj.idempotent_replay),
      installment_id: installmentId,
      contract_id: rpcObj.contract_id,
      amount_paid: rpcObj.amount_paid,
      principal_replenished: rpcObj.principal_replenished,
      contract_completed: Boolean(rpcObj.contract_completed),
      account_unfrozen: Boolean(rpcObj.account_unfrozen),
      previous_score: previousScore,
      previous_tier: previousTier,
      new_score: updated.score,
      new_tier: updated.tier,
      tier_upgraded: tierUpgraded,
      new_limits: updated.policy,
    },
    200,
    cors,
  );
});
