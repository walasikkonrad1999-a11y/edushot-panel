import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  ALLOWED_ORIGINS: "https://panel.edushot.workers.dev"
};

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

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
