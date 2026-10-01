import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker from "../src/index.js";

const env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  CAL_API_KEY: "cal_test_key",
  ALLOWED_ORIGINS: "https://panel.edushot.workers.dev"
};

function stripeRequest(payload, secret = "whsec_test_secret") {
  const raw = JSON.stringify(payload);
  const timestamp = Math.floor(Date.now() / 1000);
  const signature = createHmac("sha256", secret).update(`${timestamp}.${raw}`).digest("hex");
  return new Request("https://api.example/api/webhook/stripe", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Stripe-Signature": `t=${timestamp},v1=${signature}` },
    body: raw
  });
}

test("rejects a Stripe webhook with an invalid signature", async () => {
  const response = await worker.fetch(new Request("https://api.example/api/webhook/stripe", {
    method: "POST",
    headers: { "Stripe-Signature": `t=${Math.floor(Date.now() / 1000)},v1=${"0".repeat(64)}` },
    body: JSON.stringify({ id: "evt_invalid", type: "checkout.session.completed", data: { object: {} } })
  }), { ...env, STRIPE_WEBHOOK_SECRET: "whsec_test_secret" });
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.equal(body.error.code, "STRIPE_SIGNATURE_ERROR");
});

test("settles a paid Stripe Checkout session exactly through the database RPC", async () => {
  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input); calls.push({ url, init });
    if (url.endsWith("/rest/v1/rpc/edushot_settle_stripe_payment")) {
      return jsonResponse({ payment_id: "22222222-2222-4222-8222-222222222222", status: "succeeded" });
    }
    throw new Error(`Unexpected request: ${url}`);
  };
  try {
    const event = {
      id: "evt_paid_1", type: "checkout.session.completed", created: Math.floor(Date.now() / 1000),
      data: { object: {
        id: "cs_test_1", payment_status: "paid", payment_intent: "pi_test_1",
        amount_total: 7000, currency: "pln",
        metadata: { guardian_payment_id: "22222222-2222-4222-8222-222222222222" }
      } }
    };
    const response = await worker.fetch(stripeRequest(event), { ...env, STRIPE_WEBHOOK_SECRET: "whsec_test_secret" });
    assert.equal(response.status, 200);
    const rpc = calls.find(call => call.url.endsWith("/rest/v1/rpc/edushot_settle_stripe_payment"));
    assert.ok(rpc);
    const payload = JSON.parse(rpc.init.body);
    assert.equal(payload.p_amount_minor, 7000);
    assert.equal(payload.p_checkout_session_id, "cs_test_1");
    assert.equal(payload.p_event_id, "evt_paid_1");
  } finally { globalThis.fetch = originalFetch; }
});

test("keeps an asynchronous Stripe Checkout session pending until payment succeeds", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async input => { throw new Error(`Unexpected request: ${String(input)}`); };
  try {
    const event = {
      id: "evt_pending_1", type: "checkout.session.completed", created: Math.floor(Date.now() / 1000),
      data: { object: {
        id: "cs_test_pending", payment_status: "unpaid", amount_total: 7000, currency: "pln",
        metadata: { guardian_payment_id: "22222222-2222-4222-8222-222222222222" }
      } }
    };
    const response = await worker.fetch(stripeRequest(event), { ...env, STRIPE_WEBHOOK_SECRET: "whsec_test_secret" });
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.data.pending, true);
  } finally { globalThis.fetch = originalFetch; }
});

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

test("cancels a Cal.com lesson before the transactional database update", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input); calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    if (url.includes("/rest/v1/user_roles")) return jsonResponse([{ role: "admin" }]);
    if (url.includes("/rest/v1/lessons?")) return jsonResponse([{
      id: "22222222-2222-4222-8222-222222222222", tutor_id: "33333333-3333-4333-8333-333333333333",
      status: "scheduled", provider: "cal.com", provider_booking_id: "booking-uid", regular_plan_id: null
    }]);
    if (url === "https://api.cal.com/v2/bookings/booking-uid") return jsonResponse({ status: "cancelled" });
    if (url.endsWith("/rest/v1/rpc/edushot_admin_cancel_lesson")) return jsonResponse({ lesson_id: "22222222-2222-4222-8222-222222222222", status: "cancelled_late", cancellation_hours: 24, tutor_compensated: true });
    throw new Error(`Unexpected request: ${url}`);
  };
  try {
    const response = await worker.fetch(new Request("https://api.example/api/admin/lessons/22222222-2222-4222-8222-222222222222/cancel", {
      method: "POST", headers: { Authorization: "Bearer test-token", "Content-Type": "application/json" },
      body: JSON.stringify({ reason: "Odwołane organizacyjnie" })
    }), env);
    assert.equal(response.status, 200);
    const calIndex = calls.findIndex(call => call.url.includes("api.cal.com/v2/bookings"));
    const rpcIndex = calls.findIndex(call => call.url.endsWith("/rest/v1/rpc/edushot_admin_cancel_lesson"));
    assert.ok(calIndex >= 0 && rpcIndex > calIndex);
    assert.equal(calls[calIndex].init.method, "DELETE");
    assert.equal(JSON.parse(calls[calIndex].init.body).cancellationReason, "Odwołane organizacyjnie");
    const body = await response.json();
    assert.equal(body.data.status, "cancelled_late");
    assert.equal(body.data.tutor_compensated, true);
  } finally { globalThis.fetch = originalFetch; }
});

test("creates a regular student only after verifying the administrator", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ url, init });

    if (url.endsWith("/auth/v1/user")) {
      return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    }
    if (url.includes("/rest/v1/user_roles")) {
      return jsonResponse([{ user_id: "11111111-1111-4111-8111-111111111111", role: "admin" }]);
    }
    if (url.endsWith("/rest/v1/rpc/edushot_admin_create_regular_student")) {
      return jsonResponse("22222222-2222-4222-8222-222222222222");
    }
    throw new Error(`Unexpected request: ${url}`);
  };

  try {
    const response = await worker.fetch(
      new Request("https://api.example/api/admin/regular-students", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-token",
          Origin: "https://panel.edushot.workers.dev",
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          studentName: "Jan Kowalski",
          guardianName: "Anna Kowalska",
          guardianEmail: "ANNA@EXAMPLE.COM",
          guardianPhone: "+48 500 000 000",
          startedOn: "2026-10-01"
        })
      }),
      env
    );

    assert.equal(response.status, 201);
    const body = await response.json();
    assert.equal(body.ok, true);
    assert.equal(body.data.student_id, "22222222-2222-4222-8222-222222222222");

    const rpcCall = calls.find(call =>
      call.url.endsWith("/rest/v1/rpc/edushot_admin_create_regular_student")
    );
    assert.ok(rpcCall);
    const payload = JSON.parse(rpcCall.init.body);
    assert.equal(payload.p_guardian_email, "anna@example.com");
    assert.equal(payload.p_actor_email, "admin@edushot.pl");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("requires a reason before ending a regular cooperation", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async input => {
    const url = String(input);
    if (url.endsWith("/auth/v1/user")) {
      return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    }
    if (url.includes("/rest/v1/user_roles")) {
      return jsonResponse([{ user_id: "11111111-1111-4111-8111-111111111111", role: "admin" }]);
    }
    throw new Error(`Unexpected request: ${url}`);
  };

  try {
    const response = await worker.fetch(
      new Request(
        "https://api.example/api/admin/regular-students/22222222-2222-4222-8222-222222222222",
        {
          method: "DELETE",
          headers: {
            Authorization: "Bearer test-token",
            Origin: "https://panel.edushot.workers.dev",
            "Content-Type": "application/json"
          },
          body: JSON.stringify({ reason: "  " })
        }
      ),
      env
    );

    assert.equal(response.status, 400);
    const body = await response.json();
    assert.equal(body.error.code, "VALIDATION_ERROR");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("replaces a regular lesson plan with validated scheduling data", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) {
      return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    }
    if (url.includes("/rest/v1/user_roles")) {
      return jsonResponse([{ user_id: "11111111-1111-4111-8111-111111111111", role: "admin" }]);
    }
    if (url.endsWith("/rest/v1/rpc/edushot_admin_replace_regular_lesson_plan")) {
      return jsonResponse("33333333-3333-4333-8333-333333333333");
    }
    throw new Error(`Unexpected request: ${url}`);
  };

  try {
    const response = await worker.fetch(
      new Request("https://api.example/api/admin/regular-students/22222222-2222-4222-8222-222222222222/plan", {
        method: "PUT",
        headers: {
          Authorization: "Bearer test-token",
          Origin: "https://panel.edushot.workers.dev",
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          tutorId: "44444444-4444-4444-8444-444444444444",
          subject: "Matematyka",
          level: "Szkoła średnia — rozszerzenie",
          pricingTier: "secondary_extended",
          durationMinutes: 60,
          weekday: 3,
          startTime: "17:30",
          frequency: "weekly",
          timezone: "Europe/Warsaw",
          meetUrl: "HTTPS://MEET.GOOGLE.COM/ABC-DEFG-HIJ",
          startsOn: "2026-10-05"
        })
      }),
      env
    );

    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.data.plan_id, "33333333-3333-4333-8333-333333333333");
    const rpcCall = calls.find(call =>
      call.url.endsWith("/rest/v1/rpc/edushot_admin_replace_regular_lesson_plan")
    );
    const payload = JSON.parse(rpcCall.init.body);
    assert.equal(payload.p_meet_url, "https://meet.google.com/abc-defg-hij");
    assert.equal(payload.p_weekday, 3);
    assert.equal(calls.some(call => call.url.startsWith("https://api.cal.com")), false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("rejects a non-Google Meet link before calling the database", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async input => {
    const url = String(input);
    if (url.endsWith("/auth/v1/user")) {
      return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    }
    if (url.includes("/rest/v1/user_roles")) {
      return jsonResponse([{ user_id: "11111111-1111-4111-8111-111111111111", role: "admin" }]);
    }
    throw new Error(`Unexpected request: ${url}`);
  };

  try {
    const response = await worker.fetch(
      new Request("https://api.example/api/admin/regular-students/22222222-2222-4222-8222-222222222222/plan", {
        method: "PUT",
        headers: { Authorization: "Bearer test-token", "Content-Type": "application/json" },
        body: JSON.stringify({
          tutorId: "44444444-4444-4444-8444-444444444444",
          subject: "Matematyka", level: "Podstawa", pricingTier: "primary_school",
          durationMinutes: 60, weekday: 1, startTime: "16:00", frequency: "weekly",
          meetUrl: "https://example.com/room", startsOn: "2026-10-05"
        })
      }),
      env
    );
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, "VALIDATION_ERROR");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("generates the rolling regular lesson horizon after admin verification", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    if (url.includes("/rest/v1/user_roles")) return jsonResponse([{ role: "admin" }]);
    if (url.endsWith("/rest/v1/rpc/edushot_generate_all_regular_lessons")) {
      return jsonResponse({ plans: 1, results: [{ created: 12, conflicts: 0 }] });
    }
    throw new Error(`Unexpected request: ${url}`);
  };
  try {
    const response = await worker.fetch(new Request("https://api.example/api/admin/regular-plans/generate", {
      method: "POST", headers: { Authorization: "Bearer test-token", "Content-Type": "application/json" },
      body: JSON.stringify({ horizonDays: 90 })
    }), env);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).data.plans, 1);
    const rpcCall = calls.find(call => call.url.endsWith("/rest/v1/rpc/edushot_generate_all_regular_lessons"));
    assert.equal(JSON.parse(rpcCall.init.body).p_horizon_days, 90);
  } finally { globalThis.fetch = originalFetch; }
});

test("creates a dated break through the transactional RPC", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input); calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    if (url.includes("/rest/v1/user_roles")) return jsonResponse([{ role: "admin" }]);
    if (url.endsWith("/rest/v1/rpc/edushot_admin_add_regular_break")) return jsonResponse("55555555-5555-4555-8555-555555555555");
    throw new Error(`Unexpected request: ${url}`);
  };
  try {
    const response = await worker.fetch(new Request("https://api.example/api/admin/regular-plans/33333333-3333-4333-8333-333333333333/breaks", {
      method: "POST", headers: { Authorization: "Bearer test-token", "Content-Type": "application/json" },
      body: JSON.stringify({ dateFrom: "2026-10-10", dateTo: "2026-10-17", reason: "Wyjazd ucznia" })
    }), env);
    assert.equal(response.status, 201);
    const rpcCall = calls.find(call => call.url.endsWith("/rest/v1/rpc/edushot_admin_add_regular_break"));
    assert.equal(JSON.parse(rpcCall.init.body).p_reason, "Wyjazd ucznia");
  } finally { globalThis.fetch = originalFetch; }
});

test("assigns a substitute only through the secured RPC", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input); calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    if (url.includes("/rest/v1/user_roles")) return jsonResponse([{ role: "admin" }]);
    if (url.endsWith("/rest/v1/rpc/edushot_admin_substitute_regular_lesson")) return jsonResponse(null);
    throw new Error(`Unexpected request: ${url}`);
  };
  try {
    const response = await worker.fetch(new Request("https://api.example/api/admin/regular-lessons/66666666-6666-4666-8666-666666666666/substitute", {
      method: "POST", headers: { Authorization: "Bearer test-token", "Content-Type": "application/json" },
      body: JSON.stringify({ tutorId: "44444444-4444-4444-8444-444444444444", reason: "Urlop prowadzącego" })
    }), env);
    assert.equal(response.status, 200);
    const rpcCall = calls.find(call => call.url.endsWith("/rest/v1/rpc/edushot_admin_substitute_regular_lesson"));
    assert.equal(JSON.parse(rpcCall.init.body).p_substitute_tutor_id, "44444444-4444-4444-8444-444444444444");
  } finally { globalThis.fetch = originalFetch; }
});

test("materializes a conflicted regular occurrence through the secured substitute RPC", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input); calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    if (url.includes("/rest/v1/user_roles")) return jsonResponse([{ role: "admin" }]);
    if (url.endsWith("/rest/v1/rpc/edushot_admin_substitute_regular_occurrence")) {
      return jsonResponse("77777777-7777-4777-8777-777777777777");
    }
    throw new Error(`Unexpected request: ${url}`);
  };
  try {
    const response = await worker.fetch(new Request("https://api.example/api/admin/regular-occurrences/66666666-6666-4666-8666-666666666666/substitute", {
      method: "POST", headers: { Authorization: "Bearer test-token", "Content-Type": "application/json" },
      body: JSON.stringify({ tutorId: "44444444-4444-4444-8444-444444444444", reason: "Kolizja prowadzącego" })
    }), env);
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.data.lesson_id, "77777777-7777-4777-8777-777777777777");
    const rpcCall = calls.find(call => call.url.endsWith("/rest/v1/rpc/edushot_admin_substitute_regular_occurrence"));
    const payload = JSON.parse(rpcCall.init.body);
    assert.equal(payload.p_occurrence_id, "66666666-6666-4666-8666-666666666666");
    assert.equal(payload.p_substitute_tutor_id, "44444444-4444-4444-8444-444444444444");
  } finally { globalThis.fetch = originalFetch; }
});

test("validates an administrator-managed tutor absence before Cal.com changes", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async input => {
    const url = String(input);
    calls.push(url);
    if (url.endsWith("/auth/v1/user")) {
      return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    }
    if (url.includes("/rest/v1/user_roles")) {
      return jsonResponse([{ user_id: "11111111-1111-4111-8111-111111111111", role: "admin" }]);
    }
    throw new Error(`Unexpected request: ${url}`);
  };

  try {
    const response = await worker.fetch(
      new Request("https://api.example/api/admin/tutors/22222222-2222-4222-8222-222222222222/time-off", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-token",
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ dateFrom: "2026-10-12", dateTo: "2026-10-10", reason: "Urlop" })
      }),
      env
    );
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, "VALIDATION_ERROR");
    assert.equal(calls.some(url => url.startsWith("https://api.cal.com")), false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("adds tutor time off in Cal.com and Supabase through the admin API", async () => {
  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    calls.push({ url, init });
    if (url.endsWith("/auth/v1/user")) {
      return jsonResponse({ id: "11111111-1111-4111-8111-111111111111", email: "admin@edushot.pl" });
    }
    if (url.includes("/rest/v1/user_roles")) {
      return jsonResponse([{ user_id: "11111111-1111-4111-8111-111111111111", role: "admin" }]);
    }
    if (url.includes("/rest/v1/tutors?")) {
      return jsonResponse([{ id: "22222222-2222-4222-8222-222222222222", name: "Tutor", status: "active", cal_schedule_id: "12345", cal_regular_overrides_released_at: "2026-09-30T00:00:00Z" }]);
    }
    if (url === "https://api.cal.com/v2/schedules/12345" && (!init.method || init.method === "GET")) {
      return jsonResponse({ data: { overrides: [] } });
    }
    if (url === "https://api.cal.com/v2/schedules/12345" && init.method === "PATCH") {
      return jsonResponse({ data: { updated: true } });
    }
    if (url.includes("/rest/v1/tutor_time_off?")) {
      return jsonResponse([{ date_from: "2026-10-10", date_to: "2026-10-11" }]);
    }
    if (url.endsWith("/rest/v1/tutor_time_off")) {
      return jsonResponse({ id: "33333333-3333-4333-8333-333333333333", tutor_id: "22222222-2222-4222-8222-222222222222" });
    }
    if (url.endsWith("/rest/v1/audit_logs")) {
      return jsonResponse({ id: "44444444-4444-4444-8444-444444444444" });
    }
    throw new Error(`Unexpected request: ${url}`);
  };

  try {
    const response = await worker.fetch(
      new Request("https://api.example/api/admin/tutors/22222222-2222-4222-8222-222222222222/time-off", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-token",
          "Content-Type": "application/json"
        },
        body: JSON.stringify({ dateFrom: "2026-10-10", dateTo: "2026-10-11", reason: "Urlop" })
      }),
      env
    );
    assert.equal(response.status, 201);
    const patchCall = calls.find(call => call.url.startsWith("https://api.cal.com") && call.init.method === "PATCH");
    assert.ok(patchCall);
    assert.deepEqual(JSON.parse(patchCall.init.body).overrides, [
      { date: "2026-10-10", startTime: "00:00", endTime: "00:00" },
      { date: "2026-10-11", startTime: "00:00", endTime: "00:00" }
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
