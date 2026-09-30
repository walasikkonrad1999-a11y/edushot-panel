/**
 * EduSHOT Admin API — Cloudflare Worker
 *
 * Endpointy:
 * GET  /api/health
 * POST /api/admin/tutors
 * DELETE /api/admin/tutors/:id
 * POST /api/admin/regular-students
 * PATCH /api/admin/regular-students/:id
 * DELETE /api/admin/regular-students/:id
 * POST /api/admin/regular-students/:id/reactivate
 * PUT  /api/admin/regular-students/:id/plan
 * DELETE /api/admin/regular-students/:id/plan
 * POST /api/admin/regular-plans/generate
 * POST /api/admin/regular-plans/:id/breaks
 * POST /api/admin/regular-lessons/:id/substitute
 *
 * Wymagane Variables / Secrets w Cloudflare:
 * SUPABASE_URL
 * SUPABASE_PUBLISHABLE_KEY lub SUPABASE_ANON_KEY
 * SUPABASE_SECRET_KEY
 * TUTOR_INVITE_REDIRECT
 * ALLOWED_ORIGINS
 *
 * SUPABASE_SECRET_KEY:
 * - najlepiej nowy klucz sb_secret_...
 * - legacy service_role nadal jest obsługiwany przez ten plik
 *
 * NIGDY nie umieszczaj SUPABASE_SECRET_KEY w admin.html/korki.html/GitHubie.
 */

const DEFAULT_ALLOWED_ORIGINS = [
  "https://panel.edushot.pl"
];

function getAllowedOrigins(env) {
  return (env.ALLOWED_ORIGINS || DEFAULT_ALLOWED_ORIGINS.join(","))
    .split(",")
    .map(v => v.trim())
    .filter(Boolean);
}

function corsHeaders(request, env) {
  const origin = request.headers.get("Origin") || "";
  const allowed = getAllowedOrigins(env);
  const allowOrigin = allowed.includes(origin) ? origin : allowed[0];

  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
    "Access-Control-Allow-Headers": "Authorization,Content-Type,Accept",
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

function clean(value, max = 500) {
  return String(value ?? "").trim().slice(0, max);
}

function cleanSlug(value) {
  return clean(value, 120)
    .replace(/^https?:\/\/(www\.)?cal\.com\//i, "")
    .replace(/^\/+|\/+$/g, "");
}

function isLegacyJwtKey(key) {
  return typeof key === "string" && key.startsWith("eyJ");
}

function getPublishableKey(env) {
  return env.SUPABASE_PUBLISHABLE_KEY || env.SUPABASE_ANON_KEY || "";
}

function adminHeaders(env, extra = {}) {
  const headers = {
    "apikey": env.SUPABASE_SECRET_KEY,
    ...extra
  };

  // Legacy service_role jest JWT i może iść jako Bearer.
  // Nowy sb_secret_* powinien być przekazywany jako apikey.
  if (isLegacyJwtKey(env.SUPABASE_SECRET_KEY)) {
    headers["Authorization"] = `Bearer ${env.SUPABASE_SECRET_KEY}`;
  }

  return headers;
}

function assertConfig(env) {
  const missing = [];
  if (!env.SUPABASE_URL) missing.push("SUPABASE_URL");
  if (!getPublishableKey(env)) {
    missing.push("SUPABASE_PUBLISHABLE_KEY lub SUPABASE_ANON_KEY");
  }
  if (!env.SUPABASE_SECRET_KEY) missing.push("SUPABASE_SECRET_KEY");

  if (missing.length) {
    throw Object.assign(
      new Error(`Brak konfiguracji Workera: ${missing.join(", ")}`),
      { status: 500, code: "CONFIG_ERROR" }
    );
  }
}

async function getSignedInUser(request, env) {
  const authHeader = request.headers.get("Authorization") || "";

  if (!authHeader.startsWith("Bearer ")) {
    throw Object.assign(new Error("Brak sesji administratora."), {
      status: 401,
      code: "AUTH_ERROR"
    });
  }

  const accessToken = authHeader.slice(7).trim();

  const response = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
    headers: {
      "apikey": getPublishableKey(env),
      "Authorization": `Bearer ${accessToken}`
    }
  });

  if (!response.ok) {
    throw Object.assign(
      new Error("Sesja administratora wygasła lub jest nieprawidłowa."),
      { status: 401, code: "AUTH_ERROR" }
    );
  }

  return await response.json();
}

async function assertAdmin(user, env) {
  const url = new URL(`${env.SUPABASE_URL}/rest/v1/user_roles`);
  url.searchParams.set("select", "user_id,role");
  url.searchParams.set("user_id", `eq.${user.id}`);
  url.searchParams.set("role", "eq.admin");
  url.searchParams.set("limit", "1");

  const response = await fetch(url.toString(), {
    headers: adminHeaders(env, { "Accept": "application/json" })
  });

  if (!response.ok) {
    const details = await response.text();
    console.error("Admin role check:", response.status, details);

    throw Object.assign(
      new Error("Nie udało się zweryfikować uprawnień administratora."),
      { status: 500, code: "ROLE_CHECK_ERROR" }
    );
  }

  const rows = await response.json();

  if (!Array.isArray(rows) || rows.length === 0) {
    throw Object.assign(
      new Error("To konto nie ma uprawnień administratora."),
      { status: 403, code: "FORBIDDEN" }
    );
  }
}

async function selectOne(env, table, filters) {
  const url = new URL(`${env.SUPABASE_URL}/rest/v1/${table}`);
  url.searchParams.set("select", "*");
  url.searchParams.set("limit", "1");

  for (const [key, value] of Object.entries(filters)) {
    url.searchParams.set(key, `eq.${value}`);
  }

  const response = await fetch(url.toString(), {
    headers: adminHeaders(env, { "Accept": "application/json" })
  });

  if (!response.ok) {
    throw new Error(`Błąd odczytu tabeli ${table}: ${await response.text()}`);
  }

  const rows = await response.json();
  return rows?.[0] || null;
}

async function insertOne(env, table, row) {
  const response = await fetch(`${env.SUPABASE_URL}/rest/v1/${table}`, {
    method: "POST",
    headers: adminHeaders(env, {
      "Content-Type": "application/json",
      "Accept": "application/vnd.pgrst.object+json",
      "Prefer": "return=representation"
    }),
    body: JSON.stringify(row)
  });

  const raw = await response.text();

  if (!response.ok) {
    throw new Error(`Błąd zapisu tabeli ${table}: ${raw}`);
  }

  return raw ? JSON.parse(raw) : null;
}

async function updateOne(env, table, id, row) {
  const url = new URL(`${env.SUPABASE_URL}/rest/v1/${table}`);
  url.searchParams.set("id", `eq.${id}`);

  const response = await fetch(url.toString(), {
    method: "PATCH",
    headers: adminHeaders(env, {
      "Content-Type": "application/json",
      "Accept": "application/vnd.pgrst.object+json",
      "Prefer": "return=representation"
    }),
    body: JSON.stringify(row)
  });

  const raw = await response.text();
  if (!response.ok) {
    throw new Error(`Błąd aktualizacji tabeli ${table}: ${raw}`);
  }

  return raw ? JSON.parse(raw) : null;
}

async function callRpc(env, functionName, payload) {
  const response = await fetch(
    `${env.SUPABASE_URL}/rest/v1/rpc/${functionName}`,
    {
      method: "POST",
      headers: adminHeaders(env, {
        "Content-Type": "application/json",
        "Accept": "application/json"
      }),
      body: JSON.stringify(payload)
    }
  );

  const raw = await response.text();
  let data = null;
  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {}

  if (!response.ok) {
    throw Object.assign(
      new Error(data?.message || raw || "Nie udało się zapisać danych."),
      {
        status: response.status >= 500 ? 500 : 400,
        code: data?.code || "DATABASE_ERROR"
      }
    );
  }

  return data;
}

async function deleteRows(env, table, filters) {
  const url = new URL(`${env.SUPABASE_URL}/rest/v1/${table}`);

  for (const [key, value] of Object.entries(filters)) {
    url.searchParams.set(key, `eq.${value}`);
  }

  await fetch(url.toString(), {
    method: "DELETE",
    headers: adminHeaders(env)
  });
}

async function inviteTutor(env, email, name) {
  const url = new URL(`${env.SUPABASE_URL}/auth/v1/invite`);

  if (env.TUTOR_INVITE_REDIRECT) {
    url.searchParams.set("redirect_to", env.TUTOR_INVITE_REDIRECT);
  }

  const response = await fetch(url.toString(), {
    method: "POST",
    headers: adminHeaders(env, {
      "Content-Type": "application/json",
      "Accept": "application/json"
    }),
    body: JSON.stringify({
      email,
      data: {
        name,
        role: "tutor"
      }
    })
  });

  const raw = await response.text();

  let data = null;
  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {}

  if (!response.ok) {
    const message =
      data?.msg ||
      data?.message ||
      data?.error_description ||
      raw ||
      "Nie udało się zaprosić użytkownika.";

    throw Object.assign(new Error(message), {
      status: response.status,
      code: response.status === 422 ? "USER_EXISTS" : "AUTH_INVITE_ERROR"
    });
  }

  const userId = data?.id || data?.user?.id;

  if (!userId) {
    throw Object.assign(
      new Error("Supabase nie zwrócił ID utworzonego użytkownika."),
      { status: 500, code: "AUTH_RESPONSE_ERROR" }
    );
  }

  return userId;
}

async function deleteAuthUser(env, userId) {
  if (!userId) return;

  try {
    await fetch(
      `${env.SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
      {
        method: "DELETE",
        headers: adminHeaders(env)
      }
    );
  } catch (error) {
    console.error("Rollback auth user:", error);
  }
}

async function deleteAuthUserStrict(env, userId) {
  if (!userId) return;

  const response = await fetch(
    `${env.SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}`,
    { method: "DELETE", headers: adminHeaders(env) }
  );

  if (!response.ok && response.status !== 404) {
    const details = await response.text();
    throw Object.assign(
      new Error(`Nie udało się usunąć konta logowania: ${details}`),
      { status: 502, code: "AUTH_DELETE_ERROR" }
    );
  }
}

async function createTutor(request, env) {
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);

  let body;

  try {
    body = await request.json();
  } catch {
    throw Object.assign(new Error("Nieprawidłowe dane formularza."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }

  const name = clean(body.name, 160);
  const email = clean(body.email, 254).toLowerCase();
  const iban = clean(body.iban, 80);
  const calSlug = cleanSlug(body.calSlug);
  const calScheduleId = clean(body.calScheduleId, 120);
  const timezone = clean(body.timezone || "Europe/Warsaw", 80);

  if (name.length < 2) {
    throw Object.assign(new Error("Podaj imię i nazwisko korepetytora."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw Object.assign(new Error("Podaj prawidłowy adres e-mail."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }

  if (!calSlug) {
    throw Object.assign(new Error("Podaj Cal.com slug korepetytora."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }

  const existingTutor = await selectOne(env, "tutors", { email });

  if (existingTutor) {
    throw Object.assign(
      new Error("Korepetytor z takim adresem e-mail już istnieje."),
      { status: 409, code: "DUPLICATE_EMAIL" }
    );
  }

  let authUserId = null;
  let tutorRow = null;

  try {
    authUserId = await inviteTutor(env, email, name);

    tutorRow = await insertOne(env, "tutors", {
      auth_user_id: authUserId,
      name,
      email,
      iban: iban || null,
      cal_slug: calSlug,
      cal_url: `https://cal.com/${calSlug}`,
      cal_schedule_id: calScheduleId || null,
      timezone,
      status: "active",
      onboarding_completed: false
    });

    await insertOne(env, "user_roles", {
      user_id: authUserId,
      role: "tutor"
    });

    return {
      tutor: tutorRow,
      invitation_sent: true
    };
  } catch (error) {
    console.error("Create tutor failed:", error);

    // Best-effort rollback, żeby nie zostawić połowicznie utworzonego konta.
    if (tutorRow?.id) {
      await deleteRows(env, "tutors", { id: tutorRow.id });
    }

    if (authUserId) {
      await deleteAuthUser(env, authUserId);
    }

    throw error;
  }
}

async function removeTutor(request, env, tutorId) {
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);

  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(tutorId)) {
    throw Object.assign(new Error("Nieprawidłowe ID korepetytora."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }

  const tutor = await selectOne(env, "tutors", { id: tutorId });
  if (!tutor || tutor.status === "removed") {
    throw Object.assign(new Error("Korepetytor nie istnieje lub został już usunięty."), {
      status: 404,
      code: "TUTOR_NOT_FOUND"
    });
  }

  if (tutor.auth_user_id === admin.id) {
    throw Object.assign(new Error("Nie można usunąć własnego konta administratora."), {
      status: 409,
      code: "SELF_DELETE_BLOCKED"
    });
  }

  await deleteAuthUserStrict(env, tutor.auth_user_id);

  const removedTutor = await updateOne(env, "tutors", tutor.id, {
    auth_user_id: null,
    email: `removed+${tutor.id}@archive.edushot.local`,
    cal_slug: null,
    // cal_url is NOT NULL in the existing production schema. A unique,
    // non-routable tombstone frees the real Cal.com URL without losing history.
    cal_url: `https://archive.edushot.local/tutors/${tutor.id}`,
    cal_schedule_id: null,
    status: "removed",
    onboarding_completed: false,
    updated_at: new Date().toISOString()
  });

  if (tutor.auth_user_id) {
    await deleteRows(env, "user_roles", { user_id: tutor.auth_user_id });
  }

  try {
    await insertOne(env, "audit_logs", {
      actor_user_id: admin.id,
      actor_email: admin.email || null,
      action: "tutor_removed",
      entity_type: "tutor",
      entity_id: tutor.id,
      details: {
        tutor_name: tutor.name,
        previous_email: tutor.email,
        history_preserved: true
      }
    });
  } catch (error) {
    console.error("Tutor removal audit log:", error);
  }

  return {
    tutor: removedTutor,
    email_released: true,
    history_preserved: true
  };
}

function assertUuid(value, label = "ID") {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw Object.assign(new Error(`Nieprawidłowe ${label}.`), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }
}

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    throw Object.assign(new Error("Nieprawidłowe dane formularza."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }
}

function regularStudentPayload(body) {
  const studentName = clean(body.studentName, 160);
  const guardianName = clean(body.guardianName, 160);
  const guardianEmail = clean(body.guardianEmail, 254).toLowerCase();
  const guardianPhone = clean(body.guardianPhone, 40);
  const startedOn = clean(body.startedOn, 10);

  if (studentName.length < 2) {
    throw Object.assign(new Error("Podaj imię i nazwisko ucznia."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }
  if (guardianName.length < 2) {
    throw Object.assign(new Error("Podaj imię i nazwisko rodzica lub opiekuna."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }
  if (!guardianEmail && !guardianPhone) {
    throw Object.assign(new Error("Podaj e-mail lub telefon rodzica."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }
  if (guardianEmail && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(guardianEmail)) {
    throw Object.assign(new Error("Podaj prawidłowy e-mail rodzica."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }
  if (startedOn && !/^\d{4}-\d{2}-\d{2}$/.test(startedOn)) {
    throw Object.assign(new Error("Podaj prawidłową datę rozpoczęcia."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }

  return {
    p_student_name: studentName,
    p_guardian_name: guardianName,
    p_guardian_email: guardianEmail || null,
    p_guardian_phone: guardianPhone || null,
    p_started_on: startedOn || null
  };
}

async function createRegularStudent(request, env) {
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const payload = regularStudentPayload(await readJson(request));

  const studentId = await callRpc(
    env,
    "edushot_admin_create_regular_student",
    {
      ...payload,
      p_actor_user_id: admin.id,
      p_actor_email: admin.email || null
    }
  );

  return { student_id: studentId };
}

async function updateRegularStudent(request, env, studentId) {
  assertUuid(studentId, "ID ucznia");
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const payload = regularStudentPayload(await readJson(request));

  await callRpc(env, "edushot_admin_update_regular_student", {
    p_student_id: studentId,
    ...payload,
    p_actor_user_id: admin.id,
    p_actor_email: admin.email || null
  });

  return { student_id: studentId };
}

async function endRegularStudent(request, env, studentId) {
  assertUuid(studentId, "ID ucznia");
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const body = await readJson(request);
  const reason = clean(body.reason, 500);

  if (!reason) {
    throw Object.assign(new Error("Podaj powód zakończenia współpracy."), {
      status: 400,
      code: "VALIDATION_ERROR"
    });
  }

  await callRpc(env, "edushot_admin_set_regular_student_status", {
    p_student_id: studentId,
    p_status: "ended",
    p_reason: reason,
    p_actor_user_id: admin.id,
    p_actor_email: admin.email || null
  });

  return { student_id: studentId, status: "ended" };
}

async function reactivateRegularStudent(request, env, studentId) {
  assertUuid(studentId, "ID ucznia");
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);

  await callRpc(env, "edushot_admin_set_regular_student_status", {
    p_student_id: studentId,
    p_status: "active",
    p_reason: null,
    p_actor_user_id: admin.id,
    p_actor_email: admin.email || null
  });

  return { student_id: studentId, status: "active" };
}

function regularLessonPlanPayload(body) {
  const tutorId = clean(body.tutorId, 36);
  const subject = clean(body.subject, 120);
  const level = clean(body.level, 120);
  const pricingTier = clean(body.pricingTier, 40);
  const durationMinutes = Number(body.durationMinutes);
  const weekday = Number(body.weekday);
  const startTime = clean(body.startTime, 5);
  const frequency = clean(body.frequency, 20);
  const timezone = clean(body.timezone, 80) || "Europe/Warsaw";
  const meetUrl = clean(body.meetUrl, 500).toLowerCase();
  const startsOn = clean(body.startsOn, 10);

  assertUuid(tutorId, "ID korepetytora");
  if (!subject || !level) {
    throw Object.assign(new Error("Uzupełnij przedmiot i poziom."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (!["primary_school", "secondary_basic", "secondary_extended"].includes(pricingTier)) {
    throw Object.assign(new Error("Wybierz prawidłowy poziom rozliczeniowy."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (![30, 60, 90].includes(durationMinutes)) {
    throw Object.assign(new Error("Długość zajęć musi wynosić 30, 60 albo 90 minut."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (!Number.isInteger(weekday) || weekday < 1 || weekday > 7) {
    throw Object.assign(new Error("Wybierz prawidłowy dzień tygodnia."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(startTime)) {
    throw Object.assign(new Error("Podaj prawidłową godzinę rozpoczęcia."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (!["weekly", "biweekly"].includes(frequency)) {
    throw Object.assign(new Error("Wybierz prawidłową częstotliwość."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (!/^https:\/\/meet\.google\.com\/[a-z0-9-]+(?:[/?#].*)?$/i.test(meetUrl)) {
    throw Object.assign(new Error("Podaj prawidłowy stały link Google Meet."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(startsOn)) {
    throw Object.assign(new Error("Podaj prawidłową datę rozpoczęcia planu."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }

  return {
    p_tutor_id: tutorId,
    p_subject: subject,
    p_level: level,
    p_pricing_tier: pricingTier,
    p_duration_minutes: durationMinutes,
    p_weekday: weekday,
    p_start_time: startTime,
    p_frequency: frequency,
    p_timezone: timezone,
    p_meet_url: meetUrl,
    p_starts_on: startsOn
  };
}

async function replaceRegularLessonPlan(request, env, studentId) {
  assertUuid(studentId, "ID ucznia");
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const payload = regularLessonPlanPayload(await readJson(request));
  const planId = await callRpc(env, "edushot_admin_replace_regular_lesson_plan", {
    p_student_id: studentId,
    ...payload,
    p_actor_user_id: admin.id,
    p_actor_email: admin.email || null
  });
  return { student_id: studentId, plan_id: planId };
}

async function endRegularLessonPlan(request, env, studentId) {
  assertUuid(studentId, "ID ucznia");
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const body = await readJson(request);
  const reason = clean(body.reason, 500);
  if (!reason) {
    throw Object.assign(new Error("Podaj powód zakończenia planu."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  await callRpc(env, "edushot_admin_end_regular_lesson_plan", {
    p_student_id: studentId,
    p_reason: reason,
    p_actor_user_id: admin.id,
    p_actor_email: admin.email || null
  });
  return { student_id: studentId, status: "ended" };
}

async function generateRegularLessons(request, env) {
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const body = await readJson(request);
  const horizonDays = Number(body.horizonDays ?? 90);
  if (!Number.isInteger(horizonDays) || horizonDays < 7 || horizonDays > 366) {
    throw Object.assign(new Error("Horyzont musi obejmować od 7 do 366 dni."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  const result = await callRpc(env, "edushot_generate_all_regular_lessons", {
    p_horizon_days: horizonDays
  });
  return result;
}

async function addRegularPlanBreak(request, env, planId) {
  assertUuid(planId, "ID planu");
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const body = await readJson(request);
  const dateFrom = clean(body.dateFrom, 10);
  const dateTo = clean(body.dateTo, 10);
  const reason = clean(body.reason, 500);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(dateFrom) || !/^\d{4}-\d{2}-\d{2}$/.test(dateTo) || dateTo < dateFrom) {
    throw Object.assign(new Error("Podaj prawidłowy zakres przerwy."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  if (!reason) {
    throw Object.assign(new Error("Podaj powód przerwy."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  const breakId = await callRpc(env, "edushot_admin_add_regular_break", {
    p_plan_id: planId, p_date_from: dateFrom, p_date_to: dateTo, p_reason: reason,
    p_actor_user_id: admin.id, p_actor_email: admin.email || null
  });
  return { break_id: breakId, plan_id: planId };
}

async function substituteRegularLesson(request, env, lessonId) {
  assertUuid(lessonId, "ID lekcji");
  const admin = await getSignedInUser(request, env);
  await assertAdmin(admin, env);
  const body = await readJson(request);
  const tutorId = clean(body.tutorId, 36);
  const reason = clean(body.reason, 500);
  assertUuid(tutorId, "ID korepetytora zastępującego");
  if (!reason) {
    throw Object.assign(new Error("Podaj powód zastępstwa."), {
      status: 400, code: "VALIDATION_ERROR"
    });
  }
  await callRpc(env, "edushot_admin_substitute_regular_lesson", {
    p_lesson_id: lessonId, p_substitute_tutor_id: tutorId, p_reason: reason,
    p_actor_user_id: admin.id, p_actor_email: admin.email || null
  });
  return { lesson_id: lessonId, tutor_id: tutorId };
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: corsHeaders(request, env)
      });
    }

    try {
      assertConfig(env);

      if (request.method === "GET" && url.pathname === "/api/health") {
        return json(request, env, {
          ok: true,
          data: {
            service: "EduSHOT Admin API",
            status: "online",
            timestamp: new Date().toISOString()
          }
        });
      }

      if (request.method === "POST" && url.pathname === "/api/admin/tutors") {
        const data = await createTutor(request, env);
        return json(request, env, { ok: true, data }, 201);
      }

      if (request.method === "POST" && url.pathname === "/api/admin/regular-students") {
        const data = await createRegularStudent(request, env);
        return json(request, env, { ok: true, data }, 201);
      }

      if (request.method === "POST" && url.pathname === "/api/admin/regular-plans/generate") {
        const data = await generateRegularLessons(request, env);
        return json(request, env, { ok: true, data });
      }

      const regularPlanBreakMatch = url.pathname.match(
        /^\/api\/admin\/regular-plans\/([^/]+)\/breaks$/
      );
      if (request.method === "POST" && regularPlanBreakMatch) {
        const data = await addRegularPlanBreak(
          request, env, decodeURIComponent(regularPlanBreakMatch[1])
        );
        return json(request, env, { ok: true, data }, 201);
      }

      const regularLessonSubstituteMatch = url.pathname.match(
        /^\/api\/admin\/regular-lessons\/([^/]+)\/substitute$/
      );
      if (request.method === "POST" && regularLessonSubstituteMatch) {
        const data = await substituteRegularLesson(
          request, env, decodeURIComponent(regularLessonSubstituteMatch[1])
        );
        return json(request, env, { ok: true, data });
      }

      const regularStudentReactivateMatch = url.pathname.match(
        /^\/api\/admin\/regular-students\/([^/]+)\/reactivate$/
      );
      if (request.method === "POST" && regularStudentReactivateMatch) {
        const data = await reactivateRegularStudent(
          request,
          env,
          decodeURIComponent(regularStudentReactivateMatch[1])
        );
        return json(request, env, { ok: true, data });
      }

      const regularStudentPlanMatch = url.pathname.match(
        /^\/api\/admin\/regular-students\/([^/]+)\/plan$/
      );
      if (request.method === "PUT" && regularStudentPlanMatch) {
        const data = await replaceRegularLessonPlan(
          request, env, decodeURIComponent(regularStudentPlanMatch[1])
        );
        return json(request, env, { ok: true, data });
      }
      if (request.method === "DELETE" && regularStudentPlanMatch) {
        const data = await endRegularLessonPlan(
          request, env, decodeURIComponent(regularStudentPlanMatch[1])
        );
        return json(request, env, { ok: true, data });
      }

      const regularStudentMatch = url.pathname.match(
        /^\/api\/admin\/regular-students\/([^/]+)$/
      );
      if (request.method === "PATCH" && regularStudentMatch) {
        const data = await updateRegularStudent(
          request,
          env,
          decodeURIComponent(regularStudentMatch[1])
        );
        return json(request, env, { ok: true, data });
      }
      if (request.method === "DELETE" && regularStudentMatch) {
        const data = await endRegularStudent(
          request,
          env,
          decodeURIComponent(regularStudentMatch[1])
        );
        return json(request, env, { ok: true, data });
      }

      const tutorDeleteMatch = url.pathname.match(/^\/api\/admin\/tutors\/([^/]+)$/);
      if (request.method === "DELETE" && tutorDeleteMatch) {
        const data = await removeTutor(
          request,
          env,
          decodeURIComponent(tutorDeleteMatch[1])
        );
        return json(request, env, { ok: true, data });
      }

      return json(request, env, {
        ok: false,
        error: {
          code: "NOT_FOUND",
          message: "Nie znaleziono endpointu."
        }
      }, 404);
    } catch (error) {
      console.error("EduSHOT Admin API:", error);

      return json(request, env, {
        ok: false,
        error: {
          code: error.code || "SERVER_ERROR",
          message: error.message || "Wewnętrzny błąd serwera."
        }
      }, error.status || 500);
    }
  }
};

