/**
 * EduSHOT — Cal.com Sync Worker FINAL
 * 2026-09-23
 *
 * Endpointy:
 * GET  /api/health
 * POST /              <- webhook Cal.com
 * POST /api/webhook/calcom
 * GET  /api/tutor/availability
 * PUT  /api/tutor/availability
 * POST /api/tutor/time-off
 * DELETE /api/tutor/time-off/:providerId
 *
 * Wymagane Cloudflare Variables / Secrets:
 * SUPABASE_URL
 * SUPABASE_ANON_KEY lub SUPABASE_PUBLISHABLE_KEY
 * SUPABASE_SERVICE_ROLE_KEY lub SUPABASE_SECRET_KEY
 * CAL_API_KEY
 * CAL_WEBHOOK_SECRET
 * ALLOWED_ORIGINS=https://panel.edushot.pl
 */

const DEFAULT_PANEL_ORIGIN = "https://panel.edushot.pl";
const CAL_API_VERSION = "2024-06-11";

const DAY_TO_CAL = {
  "poniedziałek": "Monday",
  "wtorek": "Tuesday",
  "środa": "Wednesday",
  "czwartek": "Thursday",
  "piątek": "Friday",
  "sobota": "Saturday",
  "niedziela": "Sunday"
};

const CAL_TO_DAY = Object.fromEntries(
  Object.entries(DAY_TO_CAL).map(([pl, en]) => [en, pl])
);

class HttpError extends Error {
  constructor(message, status = 500, code = "SERVER_ERROR") {
    super(message);
    this.name = "HttpError";
    this.status = status;
    this.code = code;
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(request, env) });
    }

    try {
      assertConfig(env);

      if (request.method === "GET" && (path === "/" || path === "/api/health")) {
        return json(request, env, {
          ok: true,
          data: {
            service: "EduSHOT Cal.com Sync",
            status: "online",
            calApiVersion: CAL_API_VERSION,
            timestamp: new Date().toISOString()
          }
        });
      }

      if (
        request.method === "POST" &&
        (path === "/" || path === "/api/webhook/calcom")
      ) {
        return await handleWebhook(request, env);
      }

      if (request.method === "GET" && path === "/api/tutor/availability") {
        return await handleGetAvailability(request, env);
      }

      if (request.method === "PUT" && path === "/api/tutor/availability") {
        return await handleUpdateAvailability(request, env);
      }

      if (request.method === "POST" && path === "/api/tutor/time-off") {
        return await handleCreateTimeOff(request, env);
      }

      const timeOff = path.match(/^\/api\/tutor\/time-off\/(.+)$/);
      if (request.method === "DELETE" && timeOff) {
        return await handleDeleteTimeOff(
          request,
          env,
          decodeURIComponent(timeOff[1])
        );
      }

      return json(request, env, {
        ok: false,
        error: { code: "NOT_FOUND", message: "Endpoint nie istnieje." }
      }, 404);

    } catch (error) {
      console.error("EduSHOT Cal Sync:", error);

      const status = error instanceof HttpError ? error.status : 500;
      const code = error instanceof HttpError ? error.code : "SERVER_ERROR";
      const message = error instanceof Error ? error.message : "Błąd serwera.";

      return json(request, env, {
        ok: false,
        error: { code, message }
      }, status);
    }
  }
};

// ============================================================
// CONFIG / HTTP
// ============================================================

function config(env) {
  return {
    supabaseUrl: String(env.SUPABASE_URL || "").replace(/\/+$/, ""),
    publishableKey: env.SUPABASE_PUBLISHABLE_KEY || env.SUPABASE_ANON_KEY || "",
    secretKey: env.SUPABASE_SECRET_KEY || env.SUPABASE_SERVICE_ROLE_KEY || "",
    calApiKey: env.CAL_API_KEY || "",
    calWebhookSecret: env.CAL_WEBHOOK_SECRET || "",
    allowedOrigins: String(env.ALLOWED_ORIGINS || DEFAULT_PANEL_ORIGIN)
      .split(",").map(x => x.trim()).filter(Boolean)
  };
}

function assertConfig(env) {
  const c = config(env);
  const missing = [];
  if (!c.supabaseUrl) missing.push("SUPABASE_URL");
  if (!c.publishableKey) missing.push("SUPABASE_ANON_KEY lub SUPABASE_PUBLISHABLE_KEY");
  if (!c.secretKey) missing.push("SUPABASE_SERVICE_ROLE_KEY lub SUPABASE_SECRET_KEY");
  if (!c.calApiKey) missing.push("CAL_API_KEY");
  if (!c.calWebhookSecret) missing.push("CAL_WEBHOOK_SECRET");
  if (missing.length) {
    throw new HttpError(`Brak zmiennych: ${missing.join(", ")}`, 500, "CONFIG_ERROR");
  }
}

function corsHeaders(request, env) {
  const c = config(env);
  const origin = request.headers.get("Origin") || "";
  const allowOrigin = c.allowedOrigins.includes(origin)
    ? origin
    : (c.allowedOrigins[0] || DEFAULT_PANEL_ORIGIN);

  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type,Authorization,Accept",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin"
  };
}

function json(request, env, body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(request, env),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store"
    }
  });
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    throw new HttpError("Nieprawidłowy JSON.", 400, "INVALID_JSON");
  }
}

function parseJson(rawBody) {
  try {
    return JSON.parse(rawBody);
  } catch {
    throw new HttpError("Nieprawidłowy JSON.", 400, "INVALID_JSON");
  }
}

function hexToBytes(value) {
  const normalized = String(value || "").replace(/^sha256=/i, "").trim();
  if (!/^[a-f0-9]{64}$/i.test(normalized)) return null;

  return Uint8Array.from(
    normalized.match(/.{2}/g).map(byte => Number.parseInt(byte, 16))
  );
}

async function verifyCalWebhook(request, env, rawBody) {
  const signature = hexToBytes(request.headers.get("X-Cal-Signature-256"));
  if (!signature) return false;

  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(config(env).calWebhookSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"]
  );

  return crypto.subtle.verify(
    "HMAC",
    key,
    signature,
    new TextEncoder().encode(rawBody)
  );
}

function serviceHeaders(env, extra = {}) {
  const key = config(env).secretKey;

  // Stary service_role jest JWT. Nowy sb_secret_* NIE jest JWT.
  return {
    apikey: key,
    ...(typeof key === "string" && key.startsWith("eyJ")
      ? { Authorization: `Bearer ${key}` }
      : {}),
    ...extra
  };
}

// ============================================================
// AUTH TUTORA
// ============================================================

async function getSignedInUser(request, env) {
  const auth = request.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) {
    throw new HttpError("Brak autoryzacji.", 401, "AUTH_REQUIRED");
  }

  const token = auth.slice(7).trim();
  const c = config(env);

  const response = await fetch(`${c.supabaseUrl}/auth/v1/user`, {
    headers: {
      apikey: c.publishableKey,
      Authorization: `Bearer ${token}`,
      Accept: "application/json"
    }
  });

  if (!response.ok) {
    throw new HttpError(
      "Sesja wygasła. Zaloguj się ponownie.",
      401,
      "INVALID_SESSION"
    );
  }

  const user = await response.json();
  if (!user?.id) {
    throw new HttpError("Nie udało się odczytać użytkownika.", 401, "INVALID_SESSION");
  }

  return { user, token };
}

async function getTutorFromRequest(request, env) {
  const { user, token } = await getSignedInUser(request, env);
  const c = config(env);

  const url = new URL(`${c.supabaseUrl}/rest/v1/tutors`);
  url.searchParams.set("auth_user_id", `eq.${user.id}`);
  url.searchParams.set(
    "select",
    "id,auth_user_id,name,email,status,timezone,cal_slug,cal_url,cal_schedule_id,schedule_data"
  );
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: serviceHeaders(env, { Accept: "application/json" })
  });

  if (!response.ok) {
    throw new HttpError(
      `Błąd odczytu profilu korepetytora: ${await response.text()}`,
      500,
      "TUTOR_READ_ERROR"
    );
  }

  const rows = await response.json();
  const tutor = rows?.[0];

  if (!tutor) {
    throw new HttpError(
      "Nie znaleziono profilu korepetytora.",
      404,
      "TUTOR_NOT_FOUND"
    );
  }

  if (tutor.status !== "active") {
    throw new HttpError(
      "Konto korepetytora jest nieaktywne.",
      403,
      "TUTOR_INACTIVE"
    );
  }

  return { user, tutor, token };
}

// ============================================================
// CAL.COM API
// ============================================================

async function calRequest(env, endpoint, options = {}) {
  const c = config(env);

  const response = await fetch(`https://api.cal.com${endpoint}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${c.calApiKey}`,
      "cal-api-version": CAL_API_VERSION,
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(options.headers || {})
    }
  });

  const raw = await response.text();
  let data = null;

  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {
    data = raw;
  }

  if (!response.ok) {
    const message =
      data?.error?.message ||
      data?.message ||
      (typeof data === "string" ? data : null) ||
      `HTTP ${response.status}`;

    throw new HttpError(`Cal.com: ${message}`, 502, "CAL_API_ERROR");
  }

  return data;
}

// ============================================================
// DOSTĘPNOŚĆ
// ============================================================

function isTime(v) {
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(String(v || ""));
}

function minutes(v) {
  const [h, m] = String(v).split(":").map(Number);
  return h * 60 + m;
}

function validateDays(days) {
  if (!Array.isArray(days)) {
    throw new HttpError("Nieprawidłowy grafik.", 400, "INVALID_AVAILABILITY");
  }

  for (const day of days) {
    if (!day?.active) continue;

    const intervals = Array.isArray(day.intervals) ? day.intervals : [];
    if (!intervals.length) {
      throw new HttpError(
        `${day.day || "Dzień"}: dodaj co najmniej jeden przedział.`,
        400,
        "INVALID_AVAILABILITY"
      );
    }

    const sorted = [...intervals].sort((a, b) =>
      String(a.start || "").localeCompare(String(b.start || ""))
    );

    for (let i = 0; i < sorted.length; i++) {
      const it = sorted[i];

      if (!isTime(it.start) || !isTime(it.end) || minutes(it.start) >= minutes(it.end)) {
        throw new HttpError(
          `${day.day}: nieprawidłowy przedział godzinowy.`,
          400,
          "INVALID_AVAILABILITY"
        );
      }

      if (i > 0 && minutes(it.start) < minutes(sorted[i - 1].end)) {
        throw new HttpError(
          `${day.day}: przedziały nie mogą się nakładać.`,
          400,
          "INVALID_AVAILABILITY"
        );
      }
    }
  }
}

function eduShotToCal(days = []) {
  const result = [];

  for (const day of days) {
    if (!day?.active) continue;

    const calDay = DAY_TO_CAL[String(day.day || "").toLowerCase()];
    if (!calDay) continue;

    for (const interval of day.intervals || []) {
      if (!isTime(interval.start) || !isTime(interval.end)) continue;

      result.push({
        days: [calDay],
        startTime: interval.start,
        endTime: interval.end
      });
    }
  }

  return result;
}

function calToEduShot(availability = []) {
  const result = Object.keys(DAY_TO_CAL).map(day => ({
    day,
    active: false,
    intervals: []
  }));

  for (const block of Array.isArray(availability) ? availability : []) {
    for (const calDay of Array.isArray(block?.days) ? block.days : []) {
      const plDay = CAL_TO_DAY[String(calDay)];
      const target = result.find(x => x.day === plDay);
      if (!target) continue;

      const start = String(block.startTime || "").slice(0, 5);
      const end = String(block.endTime || "").slice(0, 5);
      if (!isTime(start) || !isTime(end)) continue;

      target.active = true;
      target.intervals.push({ start, end });
    }
  }

  for (const day of result) {
    day.intervals.sort((a, b) => a.start.localeCompare(b.start));
    if (!day.intervals.length) {
      day.intervals = [{ start: "16:00", end: "20:00" }];
    }
  }

  return result;
}

async function handleGetAvailability(request, env) {
  const { tutor } = await getTutorFromRequest(request, env);

  if (!tutor.cal_schedule_id) {
    throw new HttpError(
      "Ten korepetytor nie ma ustawionego Cal.com Schedule ID.",
      409,
      "MISSING_SCHEDULE_ID"
    );
  }

  const response = await calRequest(
    env,
    `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
    { method: "GET" }
  );

  const schedule = response?.data || response;

  return json(request, env, {
    ok: true,
    data: {
      availability: calToEduShot(schedule?.availability || []),
      timeZone: schedule?.timeZone || tutor.timezone || "Europe/Warsaw",
      scheduleId: tutor.cal_schedule_id,
      scheduleName: schedule?.name || null
    }
  });
}

async function handleUpdateAvailability(request, env) {
  const { tutor } = await getTutorFromRequest(request, env);

  if (!tutor.cal_schedule_id) {
    throw new HttpError(
      "Ten korepetytor nie ma ustawionego Cal.com Schedule ID.",
      409,
      "MISSING_SCHEDULE_ID"
    );
  }

  const body = await readJson(request);
  validateDays(body.days);

  const timeZone = body.timeZone || tutor.timezone || "Europe/Warsaw";

  const calResult = await calRequest(
    env,
    `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
    {
      method: "PATCH",
      body: JSON.stringify({
        timeZone,
        availability: eduShotToCal(body.days)
      })
    }
  );

  // Lokalny cache — panel nadal działa czytelnie, nawet gdy Cal.com jest chwilowo niedostępny.
  const c = config(env);
  const url = new URL(`${c.supabaseUrl}/rest/v1/tutors`);
  url.searchParams.set("id", `eq.${tutor.id}`);

  const cache = await fetch(url, {
    method: "PATCH",
    headers: serviceHeaders(env, {
      "Content-Type": "application/json",
      Prefer: "return=minimal"
    }),
    body: JSON.stringify({
      schedule_data: {
        days: body.days,
        timeZone,
        updatedAt: new Date().toISOString()
      },
      timezone: timeZone
    })
  });

  if (!cache.ok) {
    console.error("Schedule cache:", await cache.text());
  }

  return json(request, env, {
    ok: true,
    data: {
      success: true,
      scheduleId: tutor.cal_schedule_id,
      availability: body.days,
      cal: calResult?.data || calResult
    }
  });
}

// ============================================================
// NIEOBECNOŚCI / OVERRIDES
// ============================================================

function dateInZone(value, timeZone) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new HttpError("Nieprawidłowa data.", 400, "INVALID_DATE");
  }

  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit"
    }).formatToParts(date).map(p => [p.type, p.value])
  );

  return `${parts.year}-${parts.month}-${parts.day}`;
}

function datesBetween(start, end) {
  let current = new Date(`${start}T12:00:00Z`);
  const last = new Date(`${end}T12:00:00Z`);
  const result = [];

  if (
    Number.isNaN(current.getTime()) ||
    Number.isNaN(last.getTime()) ||
    current > last
  ) {
    throw new HttpError("Nieprawidłowy zakres nieobecności.", 400, "INVALID_DATE");
  }

  while (current <= last) {
    result.push(current.toISOString().slice(0, 10));
    current.setUTCDate(current.getUTCDate() + 1);
  }

  return result;
}

async function handleCreateTimeOff(request, env) {
  const { tutor } = await getTutorFromRequest(request, env);

  if (!tutor.cal_schedule_id) {
    throw new HttpError(
      "Ten korepetytor nie ma ustawionego Cal.com Schedule ID.",
      409,
      "MISSING_SCHEDULE_ID"
    );
  }

  const body = await readJson(request);
  if (!body.startAt || !body.endAt) {
    throw new HttpError(
      "Podaj początek i koniec nieobecności.",
      400,
      "INVALID_TIME_OFF"
    );
  }

  const timeZone = tutor.timezone || "Europe/Warsaw";
  const startDate = dateInZone(body.startAt, timeZone);
  const endDate = dateInZone(body.endAt, timeZone);
  const dates = datesBetween(startDate, endDate);

  const current = await calRequest(
    env,
    `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
    { method: "GET" }
  );

  const schedule = current?.data || current;
  const originalOverrides = Array.isArray(schedule?.overrides) ? [...schedule.overrides] : [];
  let overrides = [...originalOverrides];

  for (const date of dates) {
    overrides = overrides.filter(x => String(x?.date) !== date);
    overrides.push({ date, startTime: "00:00", endTime: "00:00" });
  }

  await calRequest(
    env,
    `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
    {
      method: "PATCH",
      body: JSON.stringify({ overrides })
    }
  );

  let timeOff;
  try {
    timeOff = await insertTutorTimeOff(
      env,
      tutor.id,
      startDate,
      endDate,
      cleanNullable(body.reason, 500)
    );
  } catch (error) {
    try {
      await calRequest(
        env,
        `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
        {
          method: "PATCH",
          body: JSON.stringify({ overrides: originalOverrides })
        }
      );
    } catch (rollbackError) {
      console.error("Time-off rollback error:", rollbackError);
    }
    throw error;
  }

  return json(request, env, {
    ok: true,
    data: {
      id: timeOff?.id || null,
      providerId: `${startDate}__${endDate}`,
      timeOff,
      dates
    }
  });
}

async function handleDeleteTimeOff(request, env, providerId) {
  const { tutor } = await getTutorFromRequest(request, env);

  if (!tutor.cal_schedule_id) {
    throw new HttpError(
      "Ten korepetytor nie ma ustawionego Cal.com Schedule ID.",
      409,
      "MISSING_SCHEDULE_ID"
    );
  }

  const [startDate, endDate] = String(providerId).split("__");
  if (!startDate || !endDate) {
    throw new HttpError("Nieprawidłowe ID nieobecności.", 400, "INVALID_TIME_OFF");
  }

  const blocked = new Set(datesBetween(startDate, endDate));

  const current = await calRequest(
    env,
    `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
    { method: "GET" }
  );

  const schedule = current?.data || current;
  const originalOverrides = Array.isArray(schedule?.overrides) ? [...schedule.overrides] : [];
  const overrides = originalOverrides
    .filter(x => !(
      blocked.has(String(x?.date)) &&
      String(x?.startTime) === "00:00" &&
      String(x?.endTime) === "00:00"
    ));

  await calRequest(
    env,
    `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
    {
      method: "PATCH",
      body: JSON.stringify({ overrides })
    }
  );

  try {
    await deleteTutorTimeOff(env, tutor.id, startDate, endDate);
  } catch (error) {
    try {
      await calRequest(
        env,
        `/v2/schedules/${encodeURIComponent(String(tutor.cal_schedule_id))}`,
        {
          method: "PATCH",
          body: JSON.stringify({ overrides: originalOverrides })
        }
      );
    } catch (rollbackError) {
      console.error("Time-off delete rollback error:", rollbackError);
    }
    throw error;
  }

  return json(request, env, {
    ok: true,
    data: { deleted: true }
  });
}

async function insertTutorTimeOff(env, tutorId, dateFrom, dateTo, reason) {
  const c = config(env);
  const response = await fetch(`${c.supabaseUrl}/rest/v1/tutor_time_off`, {
    method: "POST",
    headers: serviceHeaders(env, {
      "Content-Type": "application/json",
      Accept: "application/json",
      Prefer: "return=representation"
    }),
    body: JSON.stringify([{
      tutor_id: tutorId,
      date_from: dateFrom,
      date_to: dateTo,
      reason
    }])
  });

  const raw = await response.text();
  if (!response.ok) {
    throw new HttpError(
      `Błąd zapisu nieobecności: ${raw}`,
      500,
      "TIME_OFF_WRITE_ERROR"
    );
  }

  return raw ? JSON.parse(raw)?.[0] || null : null;
}

async function deleteTutorTimeOff(env, tutorId, dateFrom, dateTo) {
  const c = config(env);
  const url = new URL(`${c.supabaseUrl}/rest/v1/tutor_time_off`);
  url.searchParams.set("tutor_id", `eq.${tutorId}`);
  url.searchParams.set("date_from", `eq.${dateFrom}`);
  url.searchParams.set("date_to", `eq.${dateTo}`);

  const response = await fetch(url, {
    method: "DELETE",
    headers: serviceHeaders(env, { Prefer: "return=minimal" })
  });

  if (!response.ok) {
    throw new HttpError(
      `Błąd usuwania nieobecności: ${await response.text()}`,
      500,
      "TIME_OFF_DELETE_ERROR"
    );
  }
}

// ============================================================
// CENTRALNA POLITYKA REZERWACJI
// ============================================================

async function getBookingPolicy(env) {
  const c = config(env);
  const url = new URL(`${c.supabaseUrl}/rest/v1/booking_policy`);
  url.searchParams.set("id", "eq.1");
  url.searchParams.set(
    "select",
    "cancellation_hours,reschedule_hours,basic_tutor_rate,extended_tutor_rate,student_price,currency"
  );
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: serviceHeaders(env, { Accept: "application/json" })
  });

  if (!response.ok) {
    throw new HttpError(
      `Błąd odczytu polityki rezerwacji: ${await response.text()}`,
      500,
      "BOOKING_POLICY_ERROR"
    );
  }

  const rows = await response.json();
  return rows?.[0] || {
    cancellation_hours: 24,
    reschedule_hours: 6,
    basic_tutor_rate: 35,
    extended_tutor_rate: 40,
    student_price: 70,
    currency: "PLN"
  };
}

function actionTimestamp(envelope, booking) {
  const raw =
    booking?.cancelledAt ||
    booking?.canceledAt ||
    booking?.rescheduledAt ||
    booking?.updatedAt ||
    envelope?.createdAt ||
    envelope?.created_at ||
    null;

  const d = raw ? new Date(raw) : new Date();
  return Number.isNaN(d.getTime()) ? new Date() : d;
}

function noticeMinutes(startAt, actionAt) {
  if (!startAt) return null;
  const start = new Date(startAt);
  const action = actionAt instanceof Date ? actionAt : new Date(actionAt);
  if (Number.isNaN(start.getTime()) || Number.isNaN(action.getTime())) return null;
  return Math.floor((start.getTime() - action.getTime()) / 60000);
}

function extractOldRescheduleUid(envelope, booking) {
  const candidates = [
    booking?.rescheduledFromUid,
    booking?.rescheduleUid,
    booking?.oldBookingUid,
    booking?.rescheduledFrom?.uid,
    booking?.metadata?.rescheduledFromUid,
    envelope?.rescheduledFromUid,
    envelope?.payload?.rescheduledFromUid
  ];

  for (const value of candidates) {
    if (value != null && String(value).trim()) return String(value).trim();
  }

  return null;
}

// ============================================================
// WEBHOOK CAL.COM
// ============================================================

function eventName(envelope) {
  return String(
    envelope?.triggerEvent ||
    envelope?.type ||
    envelope?.event ||
    ""
  ).toUpperCase();
}

function bookingPayload(envelope) {
  return envelope?.payload || envelope?.data || envelope || {};
}

function bookingUid(booking) {
  return String(
    booking?.uid ||
    booking?.bookingUid ||
    booking?.bookingId ||
    booking?.id ||
    ""
  ).trim();
}

async function handleWebhook(request, env) {
  const rawBody = await request.text();

  if (!(await verifyCalWebhook(request, env, rawBody))) {
    throw new HttpError(
      "Nieprawidłowy podpis webhooka Cal.com.",
      401,
      "INVALID_WEBHOOK_SIGNATURE"
    );
  }

  const envelope = parseJson(rawBody);
  const event = eventName(envelope);
  const booking = bookingPayload(envelope);
  const uid = bookingUid(booking);
  const policy = await getBookingPolicy(env);
  const actionAt = actionTimestamp(envelope, booking);

  console.log("Cal webhook:", event || "UNKNOWN", uid || "NO_UID");

  if (!uid) {
    return json(request, env, {
      ok: true,
      data: { ignored: true, reason: "Brak booking UID" }
    });
  }

  // ======================================================
  // ANULOWANIE
  //
  // Zasada biznesowa:
  // anulowanie jest możliwe w dowolnym momencie przed lekcją.
  // >=24h przed startem: pełny zwrot, tutor 0 zł.
  // <24h przed startem: brak zwrotu, tutor pełne 35/40 zł.
  // To normalna reguła biznesowa, a nie naruszenie polityki.
  // ======================================================

  if (event.includes("CANCEL")) {
    const lesson = await getLessonByProviderId(env, uid);

    if (!lesson) {
      return json(request, env, {
        ok: true,
        data: {
          ignored: true,
          event,
          bookingId: uid,
          reason: "Lekcja nie istnieje jeszcze w EduSHOT"
        }
      });
    }

    // BOOKING_CANCELLED może pojawić się także przy flow przełożenia.
    // Jeżeli stary termin już jest oznaczony jako przełożony, nie
    // zmieniamy go ponownie i nie tworzymy wypłaty.
    if (lesson.status === "rescheduled" || lesson.rescheduled_to_booking_id) {
      return json(request, env, {
        ok: true,
        data: {
          ignored: true,
          event,
          bookingId: uid,
          reason: "Stary termin jest częścią przełożenia"
        }
      });
    }

    const notice = noticeMinutes(
      lesson.start_at || booking?.startTime || booking?.start,
      actionAt
    );

    const allowed =
      notice != null &&
      notice >= Number(policy.cancellation_hours || 24) * 60;

    const patch = allowed
      ? {
          status: "cancelled",
          cancelled_at: actionAt.toISOString(),
          cancellation_notice_minutes: notice,
          cancellation_refund_eligible: true,
          cancellation_tutor_compensation: false,
          policy_violation: false,
          policy_note: null,
          updated_at: new Date().toISOString()
        }
      : {
          status: "cancelled_late",
          cancelled_at: actionAt.toISOString(),
          cancellation_notice_minutes: notice,
          cancellation_refund_eligible: false,
          cancellation_tutor_compensation: true,
          policy_violation: false,
          policy_note:
            `Anulowanie mniej niż ${policy.cancellation_hours || 24}h przed startem — brak zwrotu, pełna stawka dla korepetytora.`,
          updated_at: new Date().toISOString()
        };

    await patchLessonById(env, lesson.id, patch);

    return json(request, env, {
      ok: true,
      data: {
        event,
        bookingId: uid,
        status: patch.status,
        noticeMinutes: notice,
        refundEligible: patch.cancellation_refund_eligible,
        tutorCompensation: patch.cancellation_tutor_compensation
      }
    });
  }

  // ======================================================
  // LOCATION / MEET
  // ======================================================

  if (event.includes("LOCATION")) {
    const meetUrl = extractMeetUrl(booking);

    if (meetUrl) {
      await patchLessonByProviderId(env, uid, {
        meet_url: meetUrl,
        updated_at: new Date().toISOString()
      });
    }

    return json(request, env, {
      ok: true,
      data: { event, bookingId: uid, meetUrl: meetUrl || null }
    });
  }

  if (
    event &&
    !event.includes("BOOKING_CREATED") &&
    !event.includes("BOOKING_RESCHEDULED") &&
    !event.includes("RESCHEDULE")
  ) {
    return json(request, env, {
      ok: true,
      data: { ignored: true, event, bookingId: uid }
    });
  }

  const tutor = await findTutorFromBooking(booking, env);

  if (!tutor) {
    const organizer =
      booking?.organizer?.email ||
      booking?.organizers?.[0]?.email ||
      booking?.hosts?.[0]?.email ||
      "brak";

    throw new HttpError(
      `Nie znaleziono korepetytora dla organizatora Cal.com: ${organizer}`,
      422,
      "TUTOR_MAPPING_ERROR"
    );
  }

  // ======================================================
  // RESCHEDULE CONTEXT
  //
  // Przełożenie jest dozwolone wyłącznie przy wyprzedzeniu >=6h
  // względem starego terminu. Cal.com powinien blokować późniejsze
  // przełożenia. Jeżeli mimo to taki webhook nadejdzie, zapisujemy
  // naruszenie do audytu, ale nadal nie tworzymy podwójnej wypłaty:
  // stary termin = 0 zł, nowy termin = jedyna potencjalnie płatna lekcja.
  // ======================================================

  const isReschedule =
    event.includes("BOOKING_RESCHEDULED") ||
    event.includes("RESCHEDULE");

  const oldUid = isReschedule ? extractOldRescheduleUid(envelope, booking) : null;
  let oldLesson = null;
  let bookingChainId = null;
  let rescheduleNotice = null;
  let rescheduleViolation = false;

  if (isReschedule) {
    if (oldUid && oldUid !== uid) {
      oldLesson = await getLessonByProviderId(env, oldUid);
    } else {
      // Niektóre flow mogą zachować UID i tylko zmienić termin.
      oldLesson = await getLessonByProviderId(env, uid);
    }

    if (oldLesson) {
      bookingChainId = oldLesson.booking_chain_id || crypto.randomUUID();
      rescheduleNotice = noticeMinutes(oldLesson.start_at, actionAt);
      rescheduleViolation =
        rescheduleNotice == null ||
        rescheduleNotice < Number(policy.reschedule_hours || 6) * 60;

      if (oldUid && oldUid !== uid) {
        await patchLessonById(env, oldLesson.id, {
          status: "rescheduled",
          rescheduled_at: actionAt.toISOString(),
          reschedule_notice_minutes: rescheduleNotice,
          rescheduled_to_booking_id: uid,
          policy_violation: rescheduleViolation,
          policy_note: rescheduleViolation
            ? `Przełożenie późniejsze niż ${policy.reschedule_hours || 6}h przed startem. ` +
              "Przełożenie poniżej limitu 6h nie powinno być dostępne w Cal.com. Stary termin nie jest rozliczany."
            : null,
          updated_at: new Date().toISOString()
        });
      }
    }
  }

  const startRaw = booking?.startTime || booking?.start || booking?.start_at;
  const endRaw = booking?.endTime || booking?.end || booking?.end_at;

  if (!startRaw) {
    throw new HttpError("Webhook nie zawiera startTime.", 422, "INVALID_BOOKING");
  }

  const start = new Date(startRaw);
  const end = endRaw
    ? new Date(endRaw)
    : new Date(
        start.getTime() +
        Number(booking?.length || booking?.duration || 60) * 60000
      );

  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) {
    throw new HttpError("Webhook zawiera nieprawidłową datę.", 422, "INVALID_BOOKING");
  }

  const timeZone =
    booking?.organizer?.timeZone ||
    booking?.organizers?.[0]?.timeZone ||
    booking?.hosts?.[0]?.timeZone ||
    booking?.timeZone ||
    tutor.timezone ||
    "Europe/Warsaw";

  const localStart = formatDateTimeInZone(start, timeZone);
  const localEnd = formatDateTimeInZone(end, timeZone);

  const title = String(
    booking?.title ||
    booking?.eventTitle ||
    booking?.eventType?.title ||
    "Matematyka"
  ).trim();

  const bookingPeople = extractBookingPeople(booking);
  const level = extractLevel(booking, title);
  const studentMessage = extractMessage(booking);
  const meetUrl = extractMeetUrl(booking);
  const bookingFields = sanitizeBookingFields(booking);

  const lesson = {
    tutor_id: tutor.id,
    booker_name: bookingPeople.bookerName,
    booker_email: bookingPeople.bookerEmail,
    student_name: bookingPeople.studentName,
    student_email: bookingPeople.studentEmail || bookingPeople.bookerEmail,
    student_message: studentMessage,
    booking_fields: bookingFields,

    subject: title || "Matematyka",
    level,

    lesson_date: localStart.date,
    time_start: localStart.time,
    time_end: localEnd.time,
    start_at: start.toISOString(),
    end_at: end.toISOString(),
    duration_minutes: Math.max(
      1,
      Math.round((end.getTime() - start.getTime()) / 60000)
    ),
    timezone: timeZone,

    status: "scheduled",
    meet_url: meetUrl,

    provider: "cal.com",
    provider_booking_id: uid,
    provider_event_type_id:
      booking?.eventTypeId != null
        ? String(booking.eventTypeId)
        : booking?.eventType?.id != null
          ? String(booking.eventType.id)
          : null,

    booking_chain_id: bookingChainId || crypto.randomUUID(),
    rescheduled_at: isReschedule ? actionAt.toISOString() : null,
    reschedule_notice_minutes: isReschedule ? rescheduleNotice : null,
    rescheduled_from_booking_id:
      isReschedule && oldLesson && oldLesson.provider_booking_id !== uid
        ? oldLesson.provider_booking_id
        : null,
    policy_violation: isReschedule ? rescheduleViolation : false,
    policy_note:
      isReschedule && rescheduleViolation
        ? `Przełożenie późniejsze niż ${policy.reschedule_hours || 6}h przed startem. ` +
          "Zdarzenie zapisano defensywnie bez podwójnego naliczenia."
        : null,

    updated_at: new Date().toISOString()
  };

  const save = await saveLessonWithoutUpsertConstraint(env, lesson);

  // Jeżeli Cal.com zachował ten sam UID przy przełożeniu, nie tworzymy
  // drugiego rekordu — saveLesson... aktualizuje istniejący wpis.
  if (isReschedule && oldLesson && oldLesson.provider_booking_id === uid && save.lesson?.id) {
    await patchLessonById(env, save.lesson.id, {
      booking_chain_id: bookingChainId || oldLesson.booking_chain_id || crypto.randomUUID(),
      rescheduled_at: actionAt.toISOString(),
      reschedule_notice_minutes: rescheduleNotice,
      policy_violation: rescheduleViolation,
      policy_note: rescheduleViolation
        ? `Przełożenie późniejsze niż ${policy.reschedule_hours || 6}h przed startem.`
        : null,
      updated_at: new Date().toISOString()
    });
  }

  if (save.lesson?.id) {
    await saveFinance(env, save.lesson.id, level, policy);

    if (save.created) {
      await createTutorNotification(env, tutor, save.lesson, bookingPeople);
    }
  }

  return json(request, env, {
    ok: true,
    data: {
      event: event || "BOOKING_CREATED",
      bookingId: uid,
      lessonId: save.lesson?.id || null,
      created: save.created,
      tutorId: tutor.id,
      studentName: bookingPeople.studentName,
      bookerName: bookingPeople.bookerName,
      bookerEmail: bookingPeople.bookerEmail,
      studentMessage,
      meetUrl,
      rescheduledFrom: oldLesson?.provider_booking_id || null,
      rescheduleNoticeMinutes: rescheduleNotice,
      policyViolation: isReschedule ? rescheduleViolation : false
    }
  });
}

// ============================================================
// FORMULARZ CAL.COM — rezerwujący / uczeń / wiadomość
// ============================================================

function valueFromResponse(raw) {
  if (raw == null) return null;
  if (typeof raw === "string" || typeof raw === "number" || typeof raw === "boolean") {
    return String(raw);
  }
  if (Array.isArray(raw)) {
    return raw.map(valueFromResponse).filter(Boolean).join(", ");
  }

  return (
    raw?.value ??
    raw?.response ??
    raw?.answer ??
    raw?.label ??
    raw?.text ??
    null
  );
}

function bookingFieldEntries(booking) {
  const pools = [
    booking?.bookingFieldsResponses,
    booking?.responses,
    booking?.userFieldsResponses
  ].filter(x => x && typeof x === "object" && !Array.isArray(x));

  const result = [];

  for (const pool of pools) {
    for (const [key, raw] of Object.entries(pool)) {
      const labelParts = [
        key,
        raw?.label,
        raw?.name,
        raw?.title,
        raw?.slug,
        raw?.identifier,
        raw?.fieldName
      ].filter(Boolean);

      const label = labelParts.join(" ").trim();
      const value = valueFromResponse(raw);

      if (value != null && String(value).trim()) {
        result.push({
          key: String(key),
          label,
          normalized: normalizeText(label),
          value: String(value).trim()
        });
      }
    }
  }

  return result;
}

function normalizeText(value) {
  return String(value || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function firstField(entries, regex) {
  return entries.find(x => regex.test(x.normalized))?.value || null;
}

function extractBookingPeople(booking) {
  const entries = bookingFieldEntries(booking);
  const attendee = booking?.attendees?.[0] || {};

  // "Twoje imię" i "Adres e-mail" są standardowymi polami bookera.
  const bookerName =
    attendee?.name ||
    firstField(entries, /(^| )(twoje imie|name|imie rezerwuj|rezerwujacy)( |$)/i) ||
    "Rezerwujący";

  const bookerEmail =
    attendee?.email ||
    firstField(entries, /(^| )(email|e mail|adres e mail)( |$)/i) ||
    null;

  // Custom field z Twojego formularza:
  // "Imię uczennicy/ucznia"
  const studentName =
    firstField(entries, /(imie.*ucz|uczenn|uczni|student)/i) ||
    bookerName ||
    "Uczeń EduSHOT";

  // Na screenie nie ma osobnego e-maila ucznia.
  // Jeżeli kiedyś dodasz takie pole, parser rozpozna je automatycznie.
  const studentEmail =
    firstField(entries, /((email|e mail).*(ucz|student)|(ucz|student).*(email|e mail))/i) ||
    null;

  return {
    bookerName: clean(bookerName, 200),
    bookerEmail: cleanNullable(bookerEmail, 320),
    studentName: clean(studentName, 200),
    studentEmail: cleanNullable(studentEmail, 320)
  };
}

function extractMessage(booking) {
  const entries = bookingFieldEntries(booking);

  const direct = [
    booking?.additionalNotes,
    booking?.notes,
    booking?.bookingFieldsResponses?.message,
    booking?.bookingFieldsResponses?.wiadomosc,
    booking?.bookingFieldsResponses?.["wiadomość"],
    booking?.responses?.message,
    booking?.responses?.notes
  ];

  for (const raw of direct) {
    const value = valueFromResponse(raw);
    if (value && String(value).trim()) {
      return clean(String(value), 5000);
    }
  }

  return cleanNullable(
    firstField(entries, /(wiadom|message|note|uwag|comment|komentarz)/i),
    5000
  );
}

function extractLevel(booking, title) {
  const entries = bookingFieldEntries(booking);
  const custom = firstField(entries, /(poziom|level|zakres|matura)/i);

  if (/rozszerz|extended/i.test(String(custom || ""))) return "Rozszerzenie";
  if (/podstaw|basic/i.test(String(custom || ""))) return "Podstawa";

  const searchable = `${title || ""} ${booking?.description || ""}`;
  return /rozszerz|extended/i.test(searchable) ? "Rozszerzenie" : "Podstawa";
}

function sanitizeBookingFields(booking) {
  const result = {};
  for (const entry of bookingFieldEntries(booking)) {
    const key = entry.key || entry.label || `field_${Object.keys(result).length + 1}`;
    result[key] = {
      label: entry.label || entry.key,
      value: entry.value
    };
  }
  return result;
}

// ============================================================
// MEET / CZAS
// ============================================================

function extractMeetUrl(booking) {
  const candidates = [
    booking?.meetingUrl,
    booking?.videoCallData?.url,
    booking?.videoCallUrl,
    booking?.metadata?.videoCallUrl,
    booking?.location?.url,
    booking?.location?.value,
    booking?.location
  ];

  for (const candidate of candidates) {
    if (typeof candidate !== "string") continue;
    const value = candidate.trim();
    if (/^https?:\/\//i.test(value)) return value;
  }

  return null;
}

function formatDateTimeInZone(date, timeZone) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: timeZone || "Europe/Warsaw",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23"
    }).formatToParts(date).map(p => [p.type, p.value])
  );

  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    time: `${parts.hour}:${parts.minute}`
  };
}

// ============================================================
// MAPOWANIE TUTORA
// ============================================================

async function findTutorFromBooking(booking, env) {
  const emails = [
    booking?.organizer?.email,
    booking?.organizers?.[0]?.email,
    booking?.hosts?.[0]?.email
  ].filter(Boolean).map(x => String(x).trim().toLowerCase());

  for (const email of [...new Set(emails)]) {
    const tutor = await findTutorByField(env, "email", email, true);
    if (tutor) return tutor;
  }

  const usernames = [
    booking?.organizer?.username,
    booking?.organizers?.[0]?.username,
    booking?.hosts?.[0]?.username
  ].filter(Boolean).map(x => String(x).trim());

  for (const username of [...new Set(usernames)]) {
    const tutor = await findTutorByField(env, "cal_slug", username, true);
    if (tutor) return tutor;
  }

  return null;
}

async function findTutorByField(env, field, value, caseInsensitive = false) {
  const c = config(env);
  const url = new URL(`${c.supabaseUrl}/rest/v1/tutors`);
  url.searchParams.set(field, `${caseInsensitive ? "ilike" : "eq"}.${value}`);
  url.searchParams.set("status", "eq.active");
  url.searchParams.set(
    "select",
    "id,auth_user_id,name,email,status,timezone,cal_slug,cal_schedule_id"
  );
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: serviceHeaders(env, { Accept: "application/json" })
  });

  if (!response.ok) {
    throw new HttpError(
      `Błąd wyszukiwania korepetytora: ${await response.text()}`,
      500,
      "TUTOR_MAPPING_ERROR"
    );
  }

  const rows = await response.json();
  return rows?.[0] || null;
}

// ============================================================
// LEKCJE — bez zależności od PostgREST on_conflict
// ============================================================

async function getLessonByProviderId(env, providerId) {
  const c = config(env);
  const url = new URL(`${c.supabaseUrl}/rest/v1/lessons`);
  url.searchParams.set("provider_booking_id", `eq.${providerId}`);
  url.searchParams.set("select", "*");
  url.searchParams.set("limit", "1");

  const response = await fetch(url, {
    headers: serviceHeaders(env, { Accept: "application/json" })
  });

  if (!response.ok) {
    throw new HttpError(
      `Błąd sprawdzania lekcji: ${await response.text()}`,
      500,
      "LESSON_READ_ERROR"
    );
  }

  const rows = await response.json();
  return rows?.[0] || null;
}

async function saveLessonWithoutUpsertConstraint(env, lesson) {
  const existing = await getLessonByProviderId(env, lesson.provider_booking_id);

  if (existing) {
    const patch = { ...lesson };

    // Retry BOOKING_CREATED nie może cofnąć żadnego stanu terminalnego,
    // także cancelled_late, rescheduled ani stanów dodanych w przyszłości.
    if (existing.status && existing.status !== "scheduled") {
      delete patch.status;
    }

    const updated = await patchLessonById(env, existing.id, patch);
    return { lesson: updated || { ...existing, ...patch }, created: false };
  }

  try {
    const created = await insertLesson(env, lesson);
    return { lesson: created, created: true };
  } catch (error) {
    // Gdy dwa retry wpadną niemal równocześnie i unikalny indeks zadziała,
    // drugi request odnajduje już utworzoną lekcję i ją aktualizuje.
    if (
      error instanceof HttpError &&
      (error.message.includes("23505") || error.message.toLowerCase().includes("duplicate"))
    ) {
      const raced = await getLessonByProviderId(env, lesson.provider_booking_id);
      if (raced) {
        const updated = await patchLessonById(env, raced.id, lesson);
        return { lesson: updated || raced, created: false };
      }
    }
    throw error;
  }
}

async function insertLesson(env, lesson) {
  const c = config(env);

  const response = await fetch(`${c.supabaseUrl}/rest/v1/lessons`, {
    method: "POST",
    headers: serviceHeaders(env, {
      "Content-Type": "application/json",
      Accept: "application/json",
      Prefer: "return=representation"
    }),
    body: JSON.stringify([lesson])
  });

  const raw = await response.text();

  if (!response.ok) {
    throw new HttpError(
      `Błąd INSERT lessons (${response.status}): ${raw}`,
      500,
      "LESSON_INSERT_ERROR"
    );
  }

  const rows = raw ? JSON.parse(raw) : [];
  return rows?.[0] || null;
}

async function patchLessonById(env, id, patch) {
  const c = config(env);
  const url = new URL(`${c.supabaseUrl}/rest/v1/lessons`);
  url.searchParams.set("id", `eq.${id}`);

  const response = await fetch(url, {
    method: "PATCH",
    headers: serviceHeaders(env, {
      "Content-Type": "application/json",
      Accept: "application/json",
      Prefer: "return=representation"
    }),
    body: JSON.stringify(patch)
  });

  const raw = await response.text();

  if (!response.ok) {
    throw new HttpError(
      `Błąd PATCH lessons (${response.status}): ${raw}`,
      500,
      "LESSON_UPDATE_ERROR"
    );
  }

  const rows = raw ? JSON.parse(raw) : [];
  return rows?.[0] || null;
}

async function patchLessonByProviderId(env, providerId, patch) {
  const existing = await getLessonByProviderId(env, providerId);
  if (!existing) {
    // Cancel/location może przyjść zanim BOOKING_CREATED zostanie zapisane.
    // Zwracamy sukces, żeby Cal.com nie retryował tego bez końca.
    return null;
  }

  return await patchLessonById(env, existing.id, patch);
}

// ============================================================
// FINANSE / POWIADOMIENIA
// ============================================================

async function saveFinance(env, lessonId, level, policy) {
  const c = config(env);
  const tutorRate = Number(
    level === "Rozszerzenie"
      ? policy?.extended_tutor_rate
      : policy?.basic_tutor_rate
  );

  if (!Number.isFinite(tutorRate) || tutorRate < 0) {
    throw new HttpError(
      "Polityka rezerwacji zawiera nieprawidłową stawkę korepetytora.",
      500,
      "BOOKING_POLICY_ERROR"
    );
  }

  const url = new URL(`${c.supabaseUrl}/rest/v1/lesson_finance`);
  url.searchParams.set("lesson_id", `eq.${lessonId}`);
  url.searchParams.set("select", "lesson_id");
  url.searchParams.set("limit", "1");

  const check = await fetch(url, {
    headers: serviceHeaders(env, { Accept: "application/json" })
  });

  const rows = check.ok ? await check.json() : [];

  if (rows?.length) {
    // Retry webhooka nie może zmienić historycznej stawki lekcji.
    return;
  }

  const response = await fetch(`${c.supabaseUrl}/rest/v1/lesson_finance`, {
    method: "POST",
    headers: serviceHeaders(env, {
      "Content-Type": "application/json",
      Prefer: "return=minimal"
    }),
    body: JSON.stringify([{
      lesson_id: lessonId,
      tutor_rate: tutorRate,
      student_price: Number(policy?.student_price ?? 70),
      payout_paid: false
    }])
  });

  if (!response.ok) {
    throw new HttpError(
      `Błąd zapisu lesson_finance: ${await response.text()}`,
      500,
      "FINANCE_ERROR"
    );
  }
}

async function createTutorNotification(env, tutor, lesson, people) {
  if (!tutor?.auth_user_id || !lesson?.id) return;

  const c = config(env);

  const response = await fetch(`${c.supabaseUrl}/rest/v1/notifications`, {
    method: "POST",
    headers: serviceHeaders(env, {
      "Content-Type": "application/json",
      Prefer: "return=minimal"
    }),
    body: JSON.stringify([{
      user_id: tutor.auth_user_id,
      type: "lesson_created",
      title: "Nowa lekcja",
      message: `${people.studentName} • ${lesson.lesson_date} ${lesson.time_start}`,
      lesson_id: lesson.id
    }])
  });

  if (!response.ok) {
    // Powiadomienie nie może zablokować zapisania rezerwacji.
    console.error("Notification error:", await response.text());
  }
}

// ============================================================
// HELPERS
// ============================================================

function clean(value, max = 500) {
  return String(value ?? "").trim().slice(0, max);
}

function cleanNullable(value, max = 500) {
  if (value == null) return null;
  const v = clean(value, max);
  return v || null;
}
