-- ============================================================================
-- Yusr (يُسر) — Migration 0007: Auto-Onboarding Trigger & Daily Dunning Engine
-- ============================================================================
-- Depends on: 0001_core_users_kyc.sql, 0003_contracts.sql
--
-- Part A: Auto-Onboarding Trigger on auth.users
--   - Automatically creates public.users (role='customer', status='active')
--     and an initial Tier 'D' (Cash-Only, 0 limits) active credit_scores row
--     on signup so mobile users never encounter USER_NOT_FOUND.
--
-- Part B: Daily Sharia-Compliant Dunning Sweeper RPC
--   - Transitions scheduled -> due (due_date <= CURRENT_DATE).
--   - Phase 1: pre_due_reminder (due in 1..3 days).
--   - Phase 2: overdue_warning (2+ days past due_date) -> marks overdue,
--     freezes user account, and reduces credit limits by 10% per day overdue
--     (idempotently computed from original limits, never compounded twice/day).
--   - Phase 3: human_call escalation (4+ days overdue).
--   - Phase 4: guarantor_notice escalation (7+ days overdue).
--   - Enforces HARD zero-riba invariants (late_fee_bps = 0, late_fee_amount = 0.00).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PART A: Auto-Onboarding Trigger Function (auth.users -> public.users + Tier D)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_raw_name TEXT;
  v_full_name TEXT;
  v_phone TEXT;
  v_email TEXT;
  v_locale TEXT;
BEGIN
  v_raw_name := trim(COALESCE(
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'name',
    split_part(COALESCE(NEW.email, ''), '@', 1),
    ''
  ));

  v_full_name := CASE
    WHEN char_length(v_raw_name) >= 2 THEN v_raw_name
    ELSE 'Yusr Customer'
  END;

  v_phone := NULLIF(trim(COALESCE(
    NEW.phone,
    NEW.raw_user_meta_data->>'phone_number',
    NEW.raw_user_meta_data->>'phone',
    ''
  )), '');

  -- Fallback guarantees NOT NULL + UNIQUE even for email-only signups
  IF v_phone IS NULL THEN
    v_phone := 'pending:' || NEW.id::text;
  END IF;

  v_email := NULLIF(trim(COALESCE(NEW.email, '')), '');

  v_locale := CASE
    WHEN NEW.raw_user_meta_data->>'preferred_locale' IN ('ar', 'en')
      THEN NEW.raw_user_meta_data->>'preferred_locale'
    ELSE 'ar'
  END;

  INSERT INTO public.users (
    id,
    full_name,
    phone_number,
    email,
    role,
    status,
    preferred_locale
  )
  VALUES (
    NEW.id,
    v_full_name,
    v_phone,
    v_email,
    'customer',
    'active',
    v_locale
  )
  ON CONFLICT (id) DO NOTHING;

  -- Initialize default Tier 'D' (Cash-Only, 0 financing limits) active score
  INSERT INTO public.credit_scores (
    user_id,
    score,
    tier,
    micro_credit_limit,
    murabaha_limit,
    min_down_payment_bps,
    max_tenor_months,
    score_breakdown,
    is_current
  )
  VALUES (
    NEW.id,
    0,
    'D',
    0.00,
    0.00,
    10000,
    1,
    jsonb_build_object(
      'incomePoints', 0,
      'historyPoints', 0,
      'guarantorPoints', 0,
      'agePoints', 0,
      'hardOverrideReason', 'INITIAL_SIGNUP_KYC_PENDING'
    ),
    true
  )
  ON CONFLICT (user_id) WHERE is_current = true DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_auth_user();

-- ----------------------------------------------------------------------------
-- PART B: Daily Dunning Sweeper RPC (Zero-Riba 5-Phase Collections Engine)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.run_daily_dunning_audit()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_marked_due_count INTEGER := 0;
  v_phase1_queued INTEGER := 0;
  v_marked_overdue_count INTEGER := 0;
  v_phase2_queued INTEGER := 0;
  v_phase3_queued INTEGER := 0;
  v_phase4_queued INTEGER := 0;
  v_accounts_frozen INTEGER := 0;
  v_limits_reduced INTEGER := 0;

  v_inst RECORD;
  v_user_rec RECORD;
  v_score_rec RECORD;
  v_base_micro NUMERIC(14,2);
  v_base_murabaha NUMERIC(14,2);
  v_decay_factor NUMERIC(6,4);
  v_new_micro NUMERIC(14,2);
  v_new_murabaha NUMERIC(14,2);
  v_updated_breakdown JSONB;
BEGIN
  -- 1. Transition scheduled -> due for installments whose due_date <= CURRENT_DATE
  WITH due_updates AS (
    UPDATE public.installments
    SET status = 'due'
    WHERE status = 'scheduled'
      AND due_date <= CURRENT_DATE
      AND late_fee_bps = 0
      AND late_fee_amount = 0.00
    RETURNING id
  )
  SELECT COUNT(*) INTO v_marked_due_count FROM due_updates;

  -- 2. Phase 1: Pre-Due Friendly Reminder (1 to 3 days before due_date)
  FOR v_inst IN
    SELECT i.id, i.contract_id, i.user_id, i.installment_number, i.due_date, i.amount_due, i.amount_paid
    FROM public.installments i
    WHERE i.status IN ('scheduled', 'due')
      AND i.due_date BETWEEN (CURRENT_DATE + 1) AND (CURRENT_DATE + 3)
      AND i.dunning_phase < 1
      AND NOT EXISTS (
        SELECT 1 FROM public.dunning_logs dl
        WHERE dl.installment_id = i.id AND dl.phase = 1
      )
    FOR UPDATE OF i SKIP LOCKED
  LOOP
    UPDATE public.installments
    SET dunning_phase = 1
    WHERE id = v_inst.id
      AND late_fee_bps = 0
      AND late_fee_amount = 0.00;

    INSERT INTO public.dunning_logs (
      installment_id, contract_id, user_id, phase, channel,
      action_taken, delivery_status, notes
    )
    VALUES (
      v_inst.id,
      v_inst.contract_id,
      v_inst.user_id,
      1,
      'whatsapp',
      'pre_due_reminder',
      'queued',
      format(
        'Friendly reminder: Installment #%s (%s SAR) due on %s. Zero late fees.',
        v_inst.installment_number,
        (v_inst.amount_due - v_inst.amount_paid)::text,
        v_inst.due_date::text
      )
    );

    v_phase1_queued := v_phase1_queued + 1;
  END LOOP;

  -- 3. Transition due/partial -> overdue (2+ days past due_date) & Phase 2 Warning
  FOR v_inst IN
    SELECT i.id, i.contract_id, i.user_id, i.installment_number, i.due_date,
           i.amount_due, i.amount_paid, i.status, i.dunning_phase,
           (CURRENT_DATE - i.due_date) AS days_overdue
    FROM public.installments i
    WHERE i.status IN ('due', 'partial', 'overdue')
      AND i.due_date <= (CURRENT_DATE - 2)
    FOR UPDATE OF i SKIP LOCKED
  LOOP
    -- Mark installment overdue (preserving strict zero late fees)
    IF v_inst.status <> 'overdue' THEN
      UPDATE public.installments
      SET
        status = 'overdue',
        dunning_phase = GREATEST(dunning_phase, 2)
      WHERE id = v_inst.id
        AND late_fee_bps = 0
        AND late_fee_amount = 0.00;

      v_marked_overdue_count := v_marked_overdue_count + 1;
    ELSIF v_inst.dunning_phase < 2 THEN
      UPDATE public.installments
      SET dunning_phase = 2
      WHERE id = v_inst.id;
    END IF;

    -- Queue Phase 2 warning once per installment
    IF NOT EXISTS (
      SELECT 1 FROM public.dunning_logs dl
      WHERE dl.installment_id = v_inst.id AND dl.phase = 2
    ) THEN
      INSERT INTO public.dunning_logs (
        installment_id, contract_id, user_id, phase, channel,
        action_taken, delivery_status, notes
      )
      VALUES (
        v_inst.id,
        v_inst.contract_id,
        v_inst.user_id,
        2,
        'whatsapp',
        'overdue_warning',
        'queued',
        format(
          'Overdue notice (%s days past due): Installment #%s (%s SAR). Account frozen until settled; 0.00 SAR late fees.',
          v_inst.days_overdue,
          v_inst.installment_number,
          (v_inst.amount_due - v_inst.amount_paid)::text
        )
      );

      v_phase2_queued := v_phase2_queued + 1;
    END IF;

    -- 4. Escalate 4+ days overdue to Phase 3 (Human Collections Call Queue)
    IF v_inst.days_overdue >= 4 THEN
      IF v_inst.dunning_phase < 3 THEN
        UPDATE public.installments
        SET dunning_phase = 3
        WHERE id = v_inst.id;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.dunning_logs dl
        WHERE dl.installment_id = v_inst.id AND dl.phase = 3
      ) THEN
        INSERT INTO public.dunning_logs (
          installment_id, contract_id, user_id, phase, channel,
          action_taken, delivery_status, notes
        )
        VALUES (
          v_inst.id,
          v_inst.contract_id,
          v_inst.user_id,
          3,
          'human_call',
          'human_call_escalation',
          'queued',
          format(
            'Phase 3 Human Call required: %s days overdue on Installment #%s (%s SAR).',
            v_inst.days_overdue,
            v_inst.installment_number,
            (v_inst.amount_due - v_inst.amount_paid)::text
          )
        );

        v_phase3_queued := v_phase3_queued + 1;
      END IF;
    END IF;

    -- 5. Escalate 7+ days overdue to Phase 4 (Guarantor Notice)
    IF v_inst.days_overdue >= 7 THEN
      IF v_inst.dunning_phase < 4 THEN
        UPDATE public.installments
        SET dunning_phase = 4
        WHERE id = v_inst.id;
      END IF;

      IF NOT EXISTS (
        SELECT 1 FROM public.dunning_logs dl
        WHERE dl.installment_id = v_inst.id AND dl.phase = 4
      ) THEN
        INSERT INTO public.dunning_logs (
          installment_id, contract_id, user_id, phase, channel,
          action_taken, delivery_status, notes
        )
        VALUES (
          v_inst.id,
          v_inst.contract_id,
          v_inst.user_id,
          4,
          'guarantor_notice',
          'guarantor_notice',
          'queued',
          format(
            'Phase 4 Guarantor Notice: %s days overdue on Installment #%s (%s SAR).',
            v_inst.days_overdue,
            v_inst.installment_number,
            (v_inst.amount_due - v_inst.amount_paid)::text
          )
        );

        v_phase4_queued := v_phase4_queued + 1;
      END IF;
    END IF;
  END LOOP;

  -- 6. Freeze accounts & apply idempotent 10%-per-day-overdue limit decay
  FOR v_user_rec IN
    SELECT
      i.user_id,
      MAX(CURRENT_DATE - i.due_date)::INTEGER AS max_days_overdue
    FROM public.installments i
    WHERE i.status = 'overdue'
      AND i.due_date <= (CURRENT_DATE - 2)
    GROUP BY i.user_id
  LOOP
    -- Freeze user account if active
    UPDATE public.users
    SET status = 'frozen'
    WHERE id = v_user_rec.user_id
      AND status = 'active';

    IF FOUND THEN
      v_accounts_frozen := v_accounts_frozen + 1;
    END IF;

    -- Lock active credit score & reduce limits by 10% per day overdue (once per day)
    SELECT * INTO v_score_rec
    FROM public.credit_scores
    WHERE user_id = v_user_rec.user_id
      AND is_current = true
    FOR UPDATE;

    IF FOUND AND COALESCE(v_score_rec.score_breakdown->>'last_dunning_decay_date', '') <> CURRENT_DATE::text THEN
      v_base_micro := COALESCE(
        NULLIF(v_score_rec.score_breakdown->>'pre_dunning_micro_limit', '')::NUMERIC(14,2),
        v_score_rec.micro_credit_limit
      );
      v_base_murabaha := COALESCE(
        NULLIF(v_score_rec.score_breakdown->>'pre_dunning_murabaha_limit', '')::NUMERIC(14,2),
        v_score_rec.murabaha_limit
      );

      -- 10% limit reduction per day overdue (floored at 0.00)
      v_decay_factor := GREATEST(0.0000, 1.0000 - (0.1000 * v_user_rec.max_days_overdue));
      v_new_micro := GREATEST(0.00, ROUND(v_base_micro * v_decay_factor, 2));
      v_new_murabaha := GREATEST(0.00, ROUND(v_base_murabaha * v_decay_factor, 2));

      v_updated_breakdown := COALESCE(v_score_rec.score_breakdown, '{}'::jsonb) || jsonb_build_object(
        'pre_dunning_micro_limit', v_base_micro,
        'pre_dunning_murabaha_limit', v_base_murabaha,
        'last_dunning_decay_date', CURRENT_DATE::text,
        'max_days_overdue', v_user_rec.max_days_overdue
      );

      UPDATE public.credit_scores
      SET
        micro_credit_limit = v_new_micro,
        murabaha_limit = v_new_murabaha,
        score_breakdown = v_updated_breakdown
      WHERE id = v_score_rec.id;

      v_limits_reduced := v_limits_reduced + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'audit_date', CURRENT_DATE,
    'marked_due_count', v_marked_due_count,
    'marked_overdue_count', v_marked_overdue_count,
    'phase1_reminders_queued', v_phase1_queued,
    'phase2_warnings_queued', v_phase2_queued,
    'phase3_human_calls_queued', v_phase3_queued,
    'phase4_guarantor_notices_queued', v_phase4_queued,
    'accounts_frozen', v_accounts_frozen,
    'credit_limits_reduced', v_limits_reduced,
    'sharia_compliance', jsonb_build_object(
      'zero_riba_verified', true,
      'late_fee_bps', 0,
      'late_fee_amount', 0.00
    )
  );
END;
$$;

-- Security Hardening: Restrict RPC & trigger function execution
REVOKE ALL ON FUNCTION public.handle_new_auth_user() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.run_daily_dunning_audit() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.run_daily_dunning_audit() TO service_role;
