import test from "node:test";
import assert from "node:assert/strict";
import {
  calculateAgeFromDob,
  calculateScore,
  getTierPolicy,
} from "./scoringRules";

test("Tier A: high income, verified guarantor, prime age, clean history", () => {
  const result = calculateScore({
    monthlyIncome: 12000,
    hasGuarantor: true,
    guarantorVerified: true,
    age: 32,
    history: {
      completedContracts: 3,
      onTimeInstallments: 12,
      totalDueInstallments: 12,
      lateInstallments: 0,
      hasActiveDefault: false,
    },
  });

  assert.equal(result.score, 100);
  assert.equal(result.tier, "A");
  assert.equal(result.policy.murabahaLimit, 25000);
  assert.equal(result.policy.microCreditLimit, 2000);
});

test("Tier B: mid income, no guarantor, neutral thin-file history", () => {
  const result = calculateScore({
    monthlyIncome: 6500, // 28 pts
    hasGuarantor: false, // 0 pts
    guarantorVerified: false,
    age: 29,             // 15 pts
    history: {
      completedContracts: 0,
      onTimeInstallments: 0,
      totalDueInstallments: 0,
      lateInstallments: 0,
      hasActiveDefault: false,
    },                   // 15 pts -> total 58 => wait: let's verify 28+0+15+15 = 58 (Tier C), with unverified guarantor = 63 (Tier B)
  });

  assert.equal(result.score, 58);
  assert.equal(result.tier, "C");

  const withGuarantor = calculateScore({
    monthlyIncome: 6500,
    hasGuarantor: true,
    guarantorVerified: true, // +15 => 73
    age: 29,
    history: {
      completedContracts: 0,
      onTimeInstallments: 0,
      totalDueInstallments: 0,
      lateInstallments: 0,
      hasActiveDefault: false,
    },
  });

  assert.equal(withGuarantor.score, 73);
  assert.equal(withGuarantor.tier, "B");
});

test("Hard override: active default forces Tier D even with high income", () => {
  const result = calculateScore({
    monthlyIncome: 15000,
    hasGuarantor: true,
    guarantorVerified: true,
    age: 35,
    history: {
      completedContracts: 4,
      onTimeInstallments: 18,
      totalDueInstallments: 20,
      lateInstallments: 2,
      hasActiveDefault: true,
    },
  });

  assert.equal(result.tier, "D");
  assert.equal(result.breakdown.hardOverrideReason, "ACTIVE_DEFAULT_DETECTED");
  assert.equal(result.policy.murabahaLimit, 0);
  assert.equal(result.policy.microCreditLimit, 0);
});

test("Hard override: applicant under 18 forces Tier D", () => {
  const result = calculateScore({
    monthlyIncome: 5000,
    hasGuarantor: true,
    guarantorVerified: true,
    age: 17,
    history: {
      completedContracts: 0,
      onTimeInstallments: 0,
      totalDueInstallments: 0,
      lateInstallments: 0,
      hasActiveDefault: false,
    },
  });

  assert.equal(result.tier, "D");
  assert.equal(result.breakdown.hardOverrideReason, "APPLICANT_UNDER_18");
  assert.deepEqual(result.policy, getTierPolicy("D"));
});

test("calculateAgeFromDob computes exact age before and after birthday", () => {
  const ref = new Date("2026-06-15T00:00:00Z");
  assert.equal(calculateAgeFromDob("2000-06-15", ref), 26);
  assert.equal(calculateAgeFromDob("2000-06-16", ref), 25);
});
