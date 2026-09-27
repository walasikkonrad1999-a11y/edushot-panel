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
    basic_tutor_rate: 35,
    extended_tutor_rate: 40,
    currency: "PLN"
  }]);

  try {
    const body = JSON.stringify({ triggerEvent: "BOOKING_CREATED", payload: {} });
    const signature = createHmac("sha256", env.CAL_WEBHOOK_SECRET)
      .update(body)
      .digest("hex");

    const response = await worker.fetch(signedRequest(body, signature), env);
    const result = await response.json();

    assert.equal(response.status, 200);
    assert.equal(result.data.ignored, true);
    assert.equal(result.data.reason, "Brak booking UID");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

