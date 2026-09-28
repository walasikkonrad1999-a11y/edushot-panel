import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";

import worker from "../src/index.js";

const env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  CAL_API_KEY: "cal_test_key",
  CAL_WEBHOOK_SECRET: "test-webhook-secret",
  ALLOWED_ORIGINS: "https://panel.example.com"
};

function signedRequest(body, signature) {
  return new Request("https://sync.example.com/api/webhook/calcom", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Cal-Signature-256": signature
    },
    body
  });
}

function signatureFor(body) {
  return createHmac("sha256", env.CAL_WEBHOOK_SECRET)
    .update(body)
    .digest("hex");
}

function policyResponse() {
  return Response.json([{
    cancellation_hours: 24,
    reschedule_hours: 6,
    currency: "PLN"
  }]);
}

test("rejects a webhook with an invalid Cal.com signature", async () => {
  const response = await worker.fetch(
    signedRequest("{}", "0".repeat(64)),
    env
  );

  assert.equal(response.status, 401);
  assert.equal(
    (await response.json()).error.code,
    "INVALID_WEBHOOK_SIGNATURE"
  );
});

test("accepts the raw-body HMAC signature produced by Cal.com", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => Response.json([{
    cancellation_hours: 24,
    reschedule_hours: 6,
    currency: "PLN"
  }]);

  try {
    const body = JSON.stringify({ triggerEvent: "BOOKING_CREATED", payload: {} });
    const signature = signatureFor(body);

    const response = await worker.fetch(signedRequest(body, signature), env);
    const result = await response.json();

    assert.equal(response.status, 200);
    assert.equal(result.data.ignored, true);
    assert.equal(result.data.reason, "Brak booking UID");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("creates an idempotent tutor notification when a lesson is cancelled", async () => {
  const originalFetch = globalThis.fetch;
  const notificationBodies = [];
  const lesson = {
    id: "00000000-0000-4000-8000-000000000101",
    tutor_id: "00000000-0000-4000-8000-000000000201",
    provider_booking_id: "booking-cancelled",
    student_name: "Uczeń testowy",
    lesson_date: "2026-10-10",
    time_start: "12:00",
    start_at: "2026-10-10T10:00:00.000Z",
    status: "scheduled",
    rescheduled_to_booking_id: null
  };

  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const method = init.method || "GET";

    if (url.pathname.endsWith("/booking_policy")) return policyResponse();
    if (url.pathname.endsWith("/lessons") && method === "GET") {
      return Response.json([lesson]);
    }
    if (url.pathname.endsWith("/lessons") && method === "PATCH") {
      return Response.json([{ ...lesson, status: "cancelled" }]);
    }
    if (url.pathname.endsWith("/tutors")) {
      return Response.json([{
        id: lesson.tutor_id,
        auth_user_id: "00000000-0000-4000-8000-000000000301",
        name: "Tutor testowy",
        status: "inactive",
        timezone: "Europe/Warsaw"
      }]);
    }
    if (url.pathname.endsWith("/notifications") && method === "POST") {
      notificationBodies.push(JSON.parse(init.body));
      assert.match(init.headers.Prefer, /resolution=ignore-duplicates/);
      return new Response(null, { status: 201 });
    }

    throw new Error(`Unexpected request: ${method} ${url}`);
  };

  try {
    const body = JSON.stringify({
      triggerEvent: "BOOKING_CANCELLED",
      createdAt: "2026-10-01T10:00:00.000Z",
      payload: { uid: lesson.provider_booking_id }
    });
    const response = await worker.fetch(signedRequest(body, signatureFor(body)), env);
    const result = await response.json();

    assert.equal(response.status, 200);
    assert.equal(result.data.status, "cancelled");
    assert.equal(notificationBodies.length, 1);
    assert.equal(notificationBodies[0][0].type, "lesson_cancelled");
    assert.equal(notificationBodies[0][0].lesson_id, lesson.id);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("notifies the tutor about the new time after a reschedule", async () => {
  const originalFetch = globalThis.fetch;
  const notificationBodies = [];
  const lessonBodies = [];
  const financeBodies = [];
  const tutor = {
    id: "00000000-0000-4000-8000-000000000202",
    auth_user_id: "00000000-0000-4000-8000-000000000302",
    name: "Tutor testowy",
    email: "tutor@example.com",
    status: "active",
    timezone: "Europe/Warsaw"
  };
  const oldLesson = {
    id: "00000000-0000-4000-8000-000000000102",
    tutor_id: tutor.id,
    provider_booking_id: "booking-old",
    booking_chain_id: "00000000-0000-4000-8000-000000000402",
    start_at: "2026-10-10T10:00:00.000Z",
    status: "scheduled"
  };
  const newLesson = {
    id: "00000000-0000-4000-8000-000000000103",
    tutor_id: tutor.id,
    provider_booking_id: "booking-new",
    student_name: "Uczeń testowy",
    lesson_date: "2026-10-11",
    time_start: "12:00",
    status: "scheduled"
  };

  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const method = init.method || "GET";

    if (url.pathname.endsWith("/booking_policy")) return policyResponse();
    if (url.pathname.endsWith("/tutors")) return Response.json([tutor]);
    if (url.pathname.endsWith("/lessons") && method === "GET") {
      const providerFilter = url.searchParams.get("provider_booking_id");
      if (providerFilter === "eq.booking-old") return Response.json([oldLesson]);
      if (providerFilter === "eq.booking-new") return Response.json([]);
    }
    if (url.pathname.endsWith("/lessons") && method === "PATCH") {
      return Response.json([{ ...oldLesson, status: "rescheduled" }]);
    }
    if (url.pathname.endsWith("/lessons") && method === "POST") {
      lessonBodies.push(JSON.parse(init.body));
      return Response.json([newLesson]);
    }
    if (url.pathname.endsWith("/lesson_pricing") && method === "GET") {
      assert.equal(url.searchParams.get("pricing_tier"), "eq.secondary_basic");
      assert.equal(url.searchParams.get("duration_minutes"), "eq.60");
      return Response.json([{ student_price: 70, tutor_rate: 40, currency: "PLN" }]);
    }
    if (url.pathname.endsWith("/lesson_finance") && method === "GET") {
      return Response.json([]);
    }
    if (url.pathname.endsWith("/lesson_finance") && method === "POST") {
      financeBodies.push(JSON.parse(init.body));
      return new Response(null, { status: 201 });
    }
    if (url.pathname.endsWith("/notifications") && method === "POST") {
      notificationBodies.push(JSON.parse(init.body));
      return new Response(null, { status: 201 });
    }

    throw new Error(`Unexpected request: ${method} ${url}`);
  };

  try {
    const body = JSON.stringify({
      triggerEvent: "BOOKING_RESCHEDULED",
      createdAt: "2026-10-01T10:00:00.000Z",
      payload: {
        uid: "booking-new",
        rescheduledFromUid: "booking-old",
        startTime: "2026-10-11T10:00:00.000Z",
        endTime: "2026-10-11T11:00:00.000Z",
        title: "Matematyka — Podstawa",
        organizer: {
          email: tutor.email,
          timeZone: "Europe/Warsaw"
        },
        attendees: [{
          name: "Uczeń testowy",
          email: "student@example.com"
        }]
      }
    });
    const response = await worker.fetch(signedRequest(body, signatureFor(body)), env);
    const result = await response.json();

    assert.equal(response.status, 200);
    assert.equal(result.data.created, true);
    assert.equal(lessonBodies[0][0].pricing_tier, "secondary_basic");
    assert.equal(financeBodies[0][0].student_price, 70);
    assert.equal(financeBodies[0][0].tutor_rate, 40);
    assert.equal(notificationBodies.length, 1);
    assert.equal(notificationBodies[0][0].type, "lesson_rescheduled");
    assert.match(notificationBodies[0][0].message, /nowy termin/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("treats Cal.com placeholder notes as an empty tutor message", async () => {
  const originalFetch = globalThis.fetch;
  let savedLesson = null;

  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(String(input));
    const method = init.method || "GET";

    if (url.pathname.endsWith("/booking_policy")) return policyResponse();
    if (url.pathname.endsWith("/tutors")) {
      return Response.json([{
        id: "00000000-0000-4000-8000-000000000210",
        auth_user_id: null,
        email: "tutor@example.com",
        status: "active",
        timezone: "Europe/Warsaw"
      }]);
    }
    if (url.pathname.endsWith("/lessons") && method === "GET") {
      return Response.json([]);
    }
    if (url.pathname.endsWith("/lessons") && method === "POST") {
      savedLesson = JSON.parse(init.body)[0];
      return Response.json([{
        ...savedLesson,
        id: "00000000-0000-4000-8000-000000000110"
      }]);
    }
    if (url.pathname.endsWith("/lesson_finance") && method === "GET") {
      return Response.json([]);
    }
    if (url.pathname.endsWith("/lesson_pricing")) {
      return Response.json([{ student_price: 40, tutor_rate: 17.5, currency: "PLN" }]);
    }
    if (url.pathname.endsWith("/lesson_finance") && method === "POST") {
      return new Response(null, { status: 201 });
    }

    throw new Error(`Unexpected request: ${method} ${url}`);
  };

  try {
    const body = JSON.stringify({
      triggerEvent: "BOOKING_CREATED",
      payload: {
        uid: "booking-placeholder-notes",
        startTime: "2026-10-12T10:00:00.000Z",
        endTime: "2026-10-12T10:30:00.000Z",
        title: "Korepetycje Matematyka Szkoła Podstawowa 30 minut.",
        organizer: { email: "tutor@example.com", timeZone: "Europe/Warsaw" },
        attendees: [{ name: "Rezerwujący", email: "student@example.com" }],
        additionalNotes: "additional_notes"
      }
    });

    const response = await worker.fetch(signedRequest(body, signatureFor(body)), env);
    assert.equal(response.status, 200);
    assert.equal(savedLesson.student_message, null);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

