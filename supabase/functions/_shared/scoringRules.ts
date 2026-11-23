/**
 * ============================================================================
 * Yusr (يُسر) — Deterministic Credit Scoring & Tier Policy Engine
 * ============================================================================
 * File: supabase/functions/_shared/scoringRules.ts
 *
 * Purpose:
 *   Pure, deterministic 0–100 scoring model and Tier (A, B, C, D) assignment
 *   using verified Income, Guarantor presence, Age, and Repayment History.
 *
 * Sharia Principles:
 *   - Zero riba / zero compounding penalties in scoring or limits.
 *   - Thin-file inclusion: new users with 0 contracts receive a neutral
 *     baseline history score (15/35) rather than being penalized to 0.
 *   - Verified guarantor provides risk-mitigation uplift without interest.
 * ============================================================================
 */

export type CreditTier = "A" | "B" | "C" | "D";

export interface RepaymentHistoryInput {
  completedContracts: number;
  onTimeInstallments: number;
  totalDueInstallments: number;
  lateInstallments: number;
  hasActiveDefault: boolean;
}

export interface ScoringInput {
  /** Verified monthly net income in base currency (e.g., SAR) */
  monthlyIncome: number;
  /** Whether the applicant declared a guarantor */
  hasGuarantor: boolean;
  /** Whether the guarantor passed KYC & consent verification */
  guarantorVerified: boolean;
  /** Applicant age in full years */
  age: number;
  /** Historical platform repayment metrics */
  history: RepaymentHistoryInput;
}

export interface ScoreBreakdown {
  incomePoints: number;     // Max 35
  historyPoints: number;    // Max 35
  guarantorPoints: number;  // Max 15
  agePoints: number;        // Max 15
  hardOverrideReason: string | null;
}

export interface TierPolicy {
  tier: CreditTier;
  /** Maximum active Qard Hasan (0% profit) micro-credit ceiling */
  microCreditLimit: number;
  /** Maximum active Murabaha financed principal ceiling */
  murabahaLimit: number;
  /** Minimum cash down payment required for Murabaha (in basis points, 1000 = 10%) */
  minDownPaymentBps: number;
  /** Maximum allowed Murabaha repayment duration in months */
  maxTenorMonths: number;
}

export interface ScoringResult {
  score: number;
  tier: CreditTier;
  breakdown: ScoreBreakdown;
  policy: TierPolicy;
}

/** Deterministic 2-decimal currency rounding helper */
export function roundCurrency(amount: number): number {
  if (!Number.isFinite(amount)) return 0;
  return Math.round((amount + Number.EPSILON) * 100) / 100;
}

/** Clamps a number inclusively between min and max */
function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/**
 * Computes full years of age from an ISO date string (YYYY-MM-DD).
 */
export function calculateAgeFromDob(
  dateOfBirth: string,
  referenceDate: Date = new Date(),
): number {
  const dob = new Date(dateOfBirth);
  if (Number.isNaN(dob.getTime())) {
    return 0;
  }
  let age = referenceDate.getUTCFullYear() - dob.getUTCFullYear();
  const monthDiff = referenceDate.getUTCMonth() - dob.getUTCMonth();
  if (
    monthDiff < 0 ||
    (monthDiff === 0 && referenceDate.getUTCDate() < dob.getUTCDate())
  ) {
    age -= 1;
  }
  return Math.max(0, age);
}

/**
 * Returns the static underwriting policy associated with each Credit Tier.
 */
export function getTierPolicy(tier: CreditTier): TierPolicy {
  switch (tier) {
    case "A":
      return {
        tier: "A",
        microCreditLimit: 2000.00,
        murabahaLimit: 25000.00,
        minDownPaymentBps: 1000, // 10.00%
        maxTenorMonths: 12,
      };
    case "B":
      return {
        tier: "B",
        microCreditLimit: 1000.00,
        murabahaLimit: 12000.00,
        minDownPaymentBps: 1500, // 15.00%
        maxTenorMonths: 9,
      };
    case "C":
      return {
        tier: "C",
        microCreditLimit: 500.00,
        murabahaLimit: 4000.00,
        minDownPaymentBps: 2500, // 25.00%
        maxTenorMonths: 6,
      };
    case "D":
    default:
      return {
        tier: "D",
        microCreditLimit: 0.00,
        murabahaLimit: 0.00,
        minDownPaymentBps: 10000, // 100.00% Cash Only
        maxTenorMonths: 1,
      };
  }
}

/**
 * Component 1: Monthly Income Points (0 – 35 pts)
 */
function scoreIncome(monthlyIncome: number): number {
  if (!Number.isFinite(monthlyIncome) || monthlyIncome <= 0) return 0;
  if (monthlyIncome < 1500) return 5;
  if (monthlyIncome < 3000) return 12;
  if (monthlyIncome < 6000) return 20;
  if (monthlyIncome < 10000) return 28;
  return 35;
}

/**
 * Component 2: Guarantor Points (0 – 15 pts)
 */
function scoreGuarantor(hasGuarantor: boolean, guarantorVerified: boolean): number {
  if (hasGuarantor && guarantorVerified) return 15;
  if (hasGuarantor && !guarantorVerified) return 5;
  return 0;
}

/**
 * Component 3: Age Stability Points (0 – 15 pts)
 */
function scoreAge(age: number): number {
  if (!Number.isFinite(age) || age < 18) return 0;
  if (age <= 21) return 6;
  if (age <= 25) return 10;
  if (age <= 55) return 15; // Prime earning years
  if (age <= 65) return 11;
  return 7;
}

/**
 * Component 4: Platform Repayment History Points (0 – 35 pts)
 */
function scoreHistory(history: RepaymentHistoryInput): number {
  if (history.hasActiveDefault) {
    return 0;
  }

  const completed = Math.max(0, Math.floor(history.completedContracts));
  const totalDue = Math.max(0, Math.floor(history.totalDueInstallments));
  const onTime = clamp(Math.floor(history.onTimeInstallments), 0, totalDue);
  const late = Math.max(0, Math.floor(history.lateInstallments));

  // New user with no installment history starts at neutral 15/35
  if (completed === 0 && totalDue === 0 && late === 0) {
    return 15;
  }

  const baseline = 15;
  const contractBonus = Math.min(12, completed * 4);
  const onTimeRatio = totalDue > 0 ? onTime / totalDue : 1;
  const punctualityBonus = Math.round(onTimeRatio * 8);
  const latePenalty = late * 5;

  return clamp(baseline + contractBonus + punctualityBonus - latePenalty, 0, 35);
}

/**
 * Assigns Tier (A, B, C, D) from numeric score and hard underwriting rules.
 */
export function assignTier(
  score: number,
  input: Pick<ScoringInput, "age" | "history">,
): { tier: CreditTier; hardOverrideReason: string | null } {
  if (!Number.isFinite(input.age) || input.age < 18) {
    return { tier: "D", hardOverrideReason: "APPLICANT_UNDER_18" };
  }
  if (input.history.hasActiveDefault) {
    return { tier: "D", hardOverrideReason: "ACTIVE_DEFAULT_DETECTED" };
  }

  if (score >= 80) return { tier: "A", hardOverrideReason: null };
  if (score >= 60) return { tier: "B", hardOverrideReason: null };
  if (score >= 40) return { tier: "C", hardOverrideReason: null };
  return { tier: "D", hardOverrideReason: null };
}

/**
 * Deterministic entry point: computes 0–100 score, assigns Tier (A/B/C/D),
 * and returns the underwriting limits and point breakdown.
 */
export function calculateScore(input: ScoringInput): ScoringResult {
  const incomePoints = scoreIncome(input.monthlyIncome);
  const guarantorPoints = scoreGuarantor(
    input.hasGuarantor,
    input.guarantorVerified,
  );
  const agePoints = scoreAge(input.age);
  const historyPoints = scoreHistory(input.history);

  const rawScore = incomePoints + guarantorPoints + agePoints + historyPoints;
  const normalizedScore =
    input.age < 18 || input.history.hasActiveDefault
      ? Math.min(clamp(Math.round(rawScore), 0, 100), 39)
      : clamp(Math.round(rawScore), 0, 100);

  const { tier, hardOverrideReason } = assignTier(normalizedScore, input);
  const policy = getTierPolicy(tier);

  return {
    score: normalizedScore,
    tier,
    breakdown: {
      incomePoints,
      historyPoints,
      guarantorPoints,
      agePoints,
      hardOverrideReason,
    },
    policy,
  };
}
