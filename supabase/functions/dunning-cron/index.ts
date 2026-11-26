/**
 * ============================================================================
 * Yusr (يُسر) — Daily Dunning & WhatsApp Notification Cron Edge Function
 * ============================================================================
 * File: supabase/functions/dunning-cron/index.ts
 * Self-contained for direct deployment from the Supabase Dashboard editor.
 *
 * Responsibilities:
 *   1. Authenticate caller (CRON_SECRET, Service Role Bearer, or Admin JWT).
 *   2. Execute supabaseAdmin.rpc("run_daily_dunning_audit").
 *   3. Fetch queued WhatsApp-dispatchable entries from dunning_logs
 *      (delivery_status = 'queued', channel IN ('whatsapp', 'guarantor_notice')).
 *   4. Dispatch messages via Meta WhatsApp Cloud API (or clean console-log
 *      mock fallback when WHATSAPP_API_TOKEN is not configured).
 *   5. Update delivery_status ('sent' or 'failed') & provider_message_id.
 * ============================================================================
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

interface DunningLogRow {
  id: string;
  installment_id: string;
  contract_id: string;
  user_id: string;
  phase: number;
  channel: string;
  action_taken: string;
  notes: string | null;
}

interface DispatchResult {
  success: boolean;
  providerMessageId: string;
  mode: "whatsapp_cloud_api" | "mock_console";
  error?: string;
}

function buildCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin");
  const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-cron-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && allowed.includes(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }
  return headers;
}

function json(
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "Content-Type": "application/json; charset=utf-8" },
  });
}

function normalizeWhatsAppRecipient(rawPhone: string | null | undefined): string | null {
  if (!rawPhone || rawPhone.startsWith("pending:")) return null;
  const digits = rawPhone.replace(/\D/g, "");
  return digits.length >= 8 ? digits : null;
}

function formatDunningMessage(
  log: DunningLogRow,
  customerName: string,
  amountDue: string,
  dueDate: string,
  locale: string,
): string {
  const isArabic = locale !== "en";

  if (log.phase === 1) {
    return isArabic
      ? `مرحباً ${customerName}، نذكركم بودّ بقرب موعد استحقاق قسطكم في منصة يُسر بمبلغ ${amountDue} بتاريخ ${dueDate}. السداد في الموعد يعزز تصنيفك الائتماني (بدون أي رسوم أو غرامات تأخير).`
      : `Hello ${customerName}, friendly reminder that your Yusr installment of ${amountDue} is due on ${dueDate}. On-time payment boosts your credit tier (0.00 late fees).`;
  }

  if (log.phase === 2) {
    return isArabic
      ? `تنبيه من منصة يُسر: تأخر سداد قسطكم بمبلغ ${amountDue} المستحق بتاريخ ${dueDate}. تم تجميد التمويل الجديد مؤقتاً لحين السداد، علماً بأنه لا توجد أي غرامات تأخير شرعاً. يرجى السداد لإعادة تفعيل حسابك.`
      : `Yusr Notice: Your installment of ${amountDue} (due ${dueDate}) is overdue. New financing is paused until settled, with zero late fees. Please repay to restore your account.`;
  }

  if (log.phase === 4) {
    return isArabic
      ? `إشعار الكفيل الموثّق من منصة يُسر: نحيطكم علماً بتأخر العميل ${customerName} عن سداد قسط مستحق بمبلغ ${amountDue} منذ تاريخ ${dueDate}. يرجى التذكير بالسداد لتسوية الالتزام ودياً (بدون أي غرامات تأخير).`
      : `Yusr Guarantor Notice: Customer ${customerName} has an overdue installment of ${amountDue} since ${dueDate}. Kindly remind them to settle amicably (zero late fees).`;
  }

  return log.notes ??
    `Yusr Payment Reminder: Installment of ${amountDue} due ${dueDate}.`;
}

async function dispatchWhatsAppMessage(
  recipientPhone: string,
  messageBody: string,
  logId: string,
): Promise<DispatchResult> {
  const token = Deno.env.get("WHATSAPP_API_TOKEN")?.trim();
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID")?.trim();
  const apiVersion = Deno.env.get("WHATSAPP_API_VERSION")?.trim() || "v20.0";

  if (!token || !phoneNumberId) {
    const mockId = `mock_wa_${logId.slice(0, 8)}_${Date.now()}`;
    console.log(
      JSON.stringify({
        event: "WHATSAPP_MOCK_DISPATCH",
        log_id: logId,
        to: recipientPhone,
        message: messageBody,
        mock_message_id: mockId,
      }),
    );
    return {
      success: true,
      providerMessageId: mockId,
      mode: "mock_console",
    };
  }

  try {
    const res = await fetch(
      `https://graph.facebook.com/${apiVersion}/${phoneNumberId}/messages`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: recipientPhone,
          type: "text",
          text: { preview_url: false, body: messageBody },
        }),
      },
    );

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      return {
        success: false,
        providerMessageId: "",
        mode: "whatsapp_cloud_api",
        error: data?.error?.message ?? `WhatsApp API HTTP ${res.status}`,
      };
    }

    const msgId = data?.messages?.[0]?.id ?? `wa_${Date.now()}`;
    return {
      success: true,
      providerMessageId: msgId,
      mode: "whatsapp_cloud_api",
    };
  } catch (err) {
    return {
      success: false,
      providerMessageId: "",
      mode: "whatsapp_cloud_api",
      error: err instanceof Error ? err.message : "Network error",
    };
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  const cors = buildCorsHeaders(req);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") {
    return json({ error: "Method not allowed. Use POST." }, 405, cors);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const cronSecret = Deno.env.get("CRON_SECRET")?.trim();

  if (!supabaseUrl || !supabaseAnonKey || !supabaseServiceKey) {
    return json({ error: "Missing Supabase environment variables." }, 500, cors);
  }

  // 1. Authenticate Scheduler / Service Role / Admin Caller
  const authHeader = req.headers.get("Authorization") ?? "";
  const reqCronSecret = req.headers.get("x-cron-secret")?.trim();
  const bearerToken = authHeader.startsWith("Bearer ")
    ? authHeader.slice(7).trim()
    : "";

  const isValidCronSecret = Boolean(
    cronSecret && (reqCronSecret === cronSecret || bearerToken === cronSecret),
  );
  const isServiceRole = bearerToken === supabaseServiceKey;

  const supabaseAdmin = createClient(supabaseUrl, supabaseServiceKey);

  if (!isValidCronSecret && !isServiceRole) {
    if (!bearerToken) {
      return json({ error: "Unauthorized: missing credentials." }, 401, cors);
    }

    const authClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
      error: authErr,
    } = await authClient.auth.getUser();

    if (authErr || !user) {
      return json({ error: "Unauthorized: invalid token." }, 401, cors);
    }

    const { data: profile } = await supabaseAdmin
      .from("users")
      .select("role")
      .eq("id", user.id)
      .maybeSingle();

    if (profile?.role !== "admin") {
      return json({ error: "Forbidden: admin or cron authorization required." }, 403, cors);
    }
  }

  // 2. Run Daily Dunning Audit RPC
  const { data: auditSummary, error: auditErr } = await supabaseAdmin.rpc(
    "run_daily_dunning_audit",
  );

  if (auditErr) {
    return json(
      { error: `Dunning audit failed: ${auditErr.message}` },
      500,
      cors,
    );
  }

  // 3. Fetch Newly Queued Automated Messages (WhatsApp & Guarantor Notice)
  const { data: queuedLogs, error: logsErr } = await supabaseAdmin
    .from("dunning_logs")
    .select("id, installment_id, contract_id, user_id, phase, channel, action_taken, notes")
    .eq("delivery_status", "queued")
    .in("channel", ["whatsapp", "guarantor_notice"])
    .order("executed_at", { ascending: true })
    .limit(100);

  if (logsErr) {
    return json(
      {
        audit: auditSummary,
        error: `Failed to fetch queued dunning logs: ${logsErr.message}`,
      },
      500,
      cors,
    );
  }

  const logs = (queuedLogs ?? []) as DunningLogRow[];
  let sentCount = 0;
  let failedCount = 0;

  if (logs.length > 0) {
    const userIds = Array.from(new Set(logs.map((l) => l.user_id)));
    const instIds = Array.from(new Set(logs.map((l) => l.installment_id)));

    const [{ data: users }, { data: kycRows }, { data: installments }] =
      await Promise.all([
        supabaseAdmin
          .from("users")
          .select("id, full_name, phone_number, preferred_locale")
          .in("id", userIds),
        supabaseAdmin
          .from("kyc_records")
          .select("user_id, guarantor_phone, guarantor_verified")
          .in("user_id", userIds),
        supabaseAdmin
          .from("installments")
          .select("id, amount_due, amount_paid, due_date")
          .in("id", instIds),
      ]);

    const userMap = new Map((users ?? []).map((u) => [u.id, u]));
    const kycMap = new Map((kycRows ?? []).map((k) => [k.user_id, k]));
    const instMap = new Map((installments ?? []).map((i) => [i.id, i]));

    // 4. Dispatch Each Queued Message & Update delivery_status
    for (const log of logs) {
      const user = userMap.get(log.user_id);
      const kyc = kycMap.get(log.user_id);
      const inst = instMap.get(log.installment_id);

      const rawTargetPhone =
        log.channel === "guarantor_notice"
          ? kyc?.guarantor_verified
            ? kyc.guarantor_phone
            : null
          : user?.phone_number;

      const recipientPhone = normalizeWhatsAppRecipient(rawTargetPhone);

      if (!recipientPhone) {
        await supabaseAdmin
          .from("dunning_logs")
          .update({
            delivery_status: "failed",
            notes: `${log.notes ?? ""} [Skipped: missing valid recipient phone]`.trim(),
          })
          .eq("id", log.id);
        failedCount += 1;
        continue;
      }

      const remaining = inst
        ? (Number(inst.amount_due) - Number(inst.amount_paid)).toFixed(2)
        : "0.00";

      const message = formatDunningMessage(
        log,
        user?.full_name ?? "Customer",
        `${remaining} SAR`,
        inst?.due_date ?? "",
        user?.preferred_locale ?? "ar",
      );

      const dispatch = await dispatchWhatsAppMessage(
        recipientPhone,
        message,
        log.id,
      );

      if (dispatch.success) {
        await supabaseAdmin
          .from("dunning_logs")
          .update({
            delivery_status: "sent",
            provider_message_id: dispatch.providerMessageId,
          })
          .eq("id", log.id);
        sentCount += 1;
      } else {
        await supabaseAdmin
          .from("dunning_logs")
          .update({
            delivery_status: "failed",
            notes: `${log.notes ?? ""} [Error: ${dispatch.error ?? "dispatch failed"}]`.trim(),
          })
          .eq("id", log.id);
        failedCount += 1;
      }
    }
  }

  return json(
    {
      ok: true,
      audit: auditSummary,
      notifications: {
        processed: logs.length,
        sent: sentCount,
        failed: failedCount,
        whatsapp_mode: Deno.env.get("WHATSAPP_API_TOKEN")?.trim()
          ? "whatsapp_cloud_api"
          : "mock_console",
      },
    },
    200,
    cors,
  );
});
