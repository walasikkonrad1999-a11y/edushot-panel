-- EduSHOT: materializacja planów stałych do lekcji, przerwy, kolizje i zastępstwa.

alter table public.lessons
  add column if not exists regular_plan_id uuid references public.regular_lesson_plans(id) on delete restrict,
  add column if not exists original_tutor_id uuid references public.tutors(id) on delete restrict,
  add column if not exists operational_note text;

create unique index if not exists lessons_regular_plan_date_uidx
  on public.lessons (regular_plan_id, lesson_date)
  where regular_plan_id is not null;
create index if not exists lessons_tutor_start_idx
  on public.lessons (tutor_id, start_at)
  where status not in ('cancelled', 'rescheduled');

create table if not exists public.regular_plan_breaks (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.regular_lesson_plans(id) on delete restrict,
  date_from date not null,
  date_to date not null,
  reason text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint regular_plan_breaks_dates_check check (date_to >= date_from),
  constraint regular_plan_breaks_reason_check check (btrim(reason) <> '')
);

create index if not exists regular_plan_breaks_plan_dates_idx
  on public.regular_plan_breaks (plan_id, date_from, date_to);

create table if not exists public.regular_lesson_occurrences (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.regular_lesson_plans(id) on delete restrict,
  occurrence_date date not null,
  planned_start_at timestamptz not null,
  planned_end_at timestamptz not null,
  status text not null,
  lesson_id uuid references public.lessons(id) on delete restrict,
  assigned_tutor_id uuid not null references public.tutors(id) on delete restrict,
  original_tutor_id uuid not null references public.tutors(id) on delete restrict,
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint regular_lesson_occurrences_status_check check (
    status in ('scheduled', 'skipped_break', 'skipped_time_off', 'conflict', 'cancelled')
  ),
  constraint regular_lesson_occurrences_time_check check (planned_end_at > planned_start_at),
  unique (plan_id, occurrence_date)
);

create index if not exists regular_occurrences_tutor_start_idx
  on public.regular_lesson_occurrences (assigned_tutor_id, planned_start_at);
create index if not exists regular_occurrences_status_date_idx
  on public.regular_lesson_occurrences (status, occurrence_date);

drop trigger if exists regular_lesson_occurrences_updated_at on public.regular_lesson_occurrences;
create trigger regular_lesson_occurrences_updated_at
before update on public.regular_lesson_occurrences
for each row execute function public.set_updated_at();

alter table public.regular_plan_breaks enable row level security;
alter table public.regular_lesson_occurrences enable row level security;

create policy regular_plan_breaks_select
on public.regular_plan_breaks for select to authenticated
using (
  (select public.is_admin())
  or exists (
    select 1 from public.regular_lesson_plans p
    join public.tutors t on t.id = p.tutor_id
    where p.id = plan_id and t.auth_user_id = (select auth.uid())
  )
);
create policy regular_plan_breaks_admin_insert
on public.regular_plan_breaks for insert to authenticated
with check ((select public.is_admin()));
create policy regular_plan_breaks_admin_update
on public.regular_plan_breaks for update to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

create policy regular_occurrences_select
on public.regular_lesson_occurrences for select to authenticated
using (
  (select public.is_admin())
  or exists (
    select 1 from public.tutors t
    where t.id = assigned_tutor_id and t.auth_user_id = (select auth.uid())
  )
);
create policy regular_occurrences_admin_insert
on public.regular_lesson_occurrences for insert to authenticated
with check ((select public.is_admin()));
create policy regular_occurrences_admin_update
on public.regular_lesson_occurrences for update to authenticated
using ((select public.is_admin())) with check ((select public.is_admin()));

revoke all on table public.regular_plan_breaks from public, anon;
revoke all on table public.regular_lesson_occurrences from public, anon;
grant select, insert, update on table public.regular_plan_breaks to authenticated;
grant select, insert, update on table public.regular_lesson_occurrences to authenticated;
grant select, insert, update, delete on table public.regular_plan_breaks to service_role;
grant select, insert, update, delete on table public.regular_lesson_occurrences to service_role;

create or replace function public.edushot_generate_regular_plan_lessons(
  p_plan_id uuid,
  p_horizon_days integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.regular_lesson_plans%rowtype;
  v_student public.students%rowtype;
  v_guardian_email text;
  v_day date;
  v_start timestamptz;
  v_end timestamptz;
  v_status text;
  v_reason text;
  v_lesson_id uuid;
  v_created integer := 0;
  v_existing integer := 0;
  v_skipped integer := 0;
  v_conflicts integer := 0;
begin
  if p_horizon_days < 7 or p_horizon_days > 366 then
    raise exception 'Horyzont musi obejmować od 7 do 366 dni.' using errcode = '22023';
  end if;

  select * into v_plan from public.regular_lesson_plans
  where id = p_plan_id and status = 'active';
  if not found then
    raise exception 'Nie znaleziono aktywnego planu.' using errcode = 'P0002';
  end if;

  select * into v_student from public.students
  where id = v_plan.student_id and status = 'active';
  if not found then
    raise exception 'Uczeń nie jest aktywny.' using errcode = 'P0002';
  end if;

  select g.email into v_guardian_email
  from public.student_guardians sg
  join public.guardians g on g.id = sg.guardian_id
  where sg.student_id = v_student.id and sg.is_primary
  limit 1;

  for v_day in
    select d::date
    from generate_series(
      greatest(v_plan.starts_on, current_date)::timestamp,
      least(coalesce(v_plan.ends_on, current_date + p_horizon_days), current_date + p_horizon_days)::timestamp,
      interval '1 day'
    ) d
    where extract(isodow from d)::integer = v_plan.weekday
      and (
        v_plan.frequency = 'weekly'
        or mod((d::date - v_plan.starts_on), 14) = 0
      )
  loop
    if exists (
      select 1 from public.regular_lesson_occurrences
      where plan_id = v_plan.id and occurrence_date = v_day
    ) then
      v_existing := v_existing + 1;
      continue;
    end if;

    v_start := (v_day + v_plan.start_time) at time zone v_plan.timezone;
    v_end := v_start + make_interval(mins => v_plan.duration_minutes);
    v_status := 'scheduled';
    v_reason := null;
    v_lesson_id := null;

    if exists (
      select 1 from public.regular_plan_breaks b
      where b.plan_id = v_plan.id and v_day between b.date_from and b.date_to
    ) then
      v_status := 'skipped_break';
      select b.reason into v_reason from public.regular_plan_breaks b
      where b.plan_id = v_plan.id and v_day between b.date_from and b.date_to
      order by b.created_at desc limit 1;
      v_skipped := v_skipped + 1;
    elsif exists (
      select 1 from public.tutor_time_off o
      where o.tutor_id = v_plan.tutor_id and v_day between o.date_from and o.date_to
    ) then
      v_status := 'skipped_time_off';
      select coalesce(o.reason, 'Urlop korepetytora') into v_reason
      from public.tutor_time_off o
      where o.tutor_id = v_plan.tutor_id and v_day between o.date_from and o.date_to
      order by o.created_at desc limit 1;
      v_skipped := v_skipped + 1;
    elsif exists (
      select 1 from public.lessons l
      where l.tutor_id = v_plan.tutor_id
        and l.status not in ('cancelled', 'rescheduled')
        and l.start_at is not null and l.end_at is not null
        and tstzrange(l.start_at, l.end_at, '[)') && tstzrange(v_start, v_end, '[)')
    ) then
      v_status := 'conflict';
      v_reason := 'Korepetytor ma w tym czasie inną lekcję.';
      v_conflicts := v_conflicts + 1;
    else
      insert into public.lessons (
        tutor_id, student_id, student_name, student_email, subject, level,
        rate, lesson_date, time_start, time_end, meet_url, status,
        start_at, end_at, duration_minutes, timezone, provider, pricing_tier,
        regular_plan_id, original_tutor_id, operational_note
      ) values (
        v_plan.tutor_id, v_student.id, v_student.name, v_guardian_email,
        v_plan.subject, v_plan.level,
        case v_plan.pricing_tier when 'primary_school' then 35 when 'secondary_basic' then 40 else 45 end,
        v_day,
        to_char(v_start at time zone v_plan.timezone, 'HH24:MI'),
        to_char(v_end at time zone v_plan.timezone, 'HH24:MI'),
        v_plan.meet_url, 'scheduled', v_start, v_end, v_plan.duration_minutes,
        v_plan.timezone, 'edushot_regular', v_plan.pricing_tier,
        v_plan.id, v_plan.tutor_id, 'Lekcja wygenerowana z planu stałego.'
      ) returning id into v_lesson_id;
      v_created := v_created + 1;
    end if;

    insert into public.regular_lesson_occurrences (
      plan_id, occurrence_date, planned_start_at, planned_end_at, status,
      lesson_id, assigned_tutor_id, original_tutor_id, reason
    ) values (
      v_plan.id, v_day, v_start, v_end, v_status,
      v_lesson_id, v_plan.tutor_id, v_plan.tutor_id, v_reason
    );
  end loop;

  return jsonb_build_object(
    'plan_id', v_plan.id, 'created', v_created, 'existing', v_existing,
    'skipped', v_skipped, 'conflicts', v_conflicts
  );
end;
$$;

create or replace function public.edushot_generate_all_regular_lessons(
  p_horizon_days integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_id uuid;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
begin
  for v_plan_id in
    select id from public.regular_lesson_plans where status = 'active' order by created_at
  loop
    v_result := public.edushot_generate_regular_plan_lessons(v_plan_id, p_horizon_days);
    v_results := v_results || jsonb_build_array(v_result);
  end loop;
  return jsonb_build_object('plans', jsonb_array_length(v_results), 'results', v_results);
end;
$$;

create or replace function public.edushot_admin_add_regular_break(
  p_plan_id uuid,
  p_date_from date,
  p_date_to date,
  p_reason text,
  p_actor_user_id uuid,
  p_actor_email text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_break_id uuid;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if p_date_from is null or p_date_to is null or p_date_to < p_date_from then
    raise exception 'Podaj prawidłowy zakres przerwy.' using errcode = '22023';
  end if;
  if v_reason is null then
    raise exception 'Podaj powód przerwy.' using errcode = '22023';
  end if;
  perform 1 from public.regular_lesson_plans where id = p_plan_id for update;
  if not found then raise exception 'Nie znaleziono planu.' using errcode = 'P0002'; end if;

  insert into public.regular_plan_breaks (plan_id, date_from, date_to, reason, created_by)
  values (p_plan_id, p_date_from, p_date_to, v_reason, p_actor_user_id)
  returning id into v_break_id;

  update public.lessons
  set status = 'cancelled', cancelled_at = now(), cancellation_tutor_compensation = false,
      policy_note = 'Przerwa w planie stałym: ' || v_reason,
      operational_note = 'Lekcja pominięta: ' || v_reason
  where regular_plan_id = p_plan_id
    and lesson_date between p_date_from and p_date_to
    and start_at > now()
    and status in ('scheduled', 'confirmed');

  update public.regular_lesson_occurrences
  set status = 'skipped_break', reason = v_reason
  where plan_id = p_plan_id and occurrence_date between p_date_from and p_date_to;

  insert into public.audit_logs (actor_user_id, actor_email, action, entity_type, entity_id, details)
  values (p_actor_user_id, p_actor_email, 'regular_plan_break_added', 'regular_plan_break', v_break_id::text,
    jsonb_build_object('plan_id', p_plan_id, 'date_from', p_date_from, 'date_to', p_date_to, 'reason', v_reason));
  return v_break_id;
end;
$$;

create or replace function public.edushot_admin_substitute_regular_lesson(
  p_lesson_id uuid,
  p_substitute_tutor_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_actor_email text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lesson public.lessons%rowtype;
  v_reason text := nullif(btrim(p_reason), '');
  v_substitute_auth uuid;
begin
  if v_reason is null then raise exception 'Podaj powód zastępstwa.' using errcode = '22023'; end if;
  select * into v_lesson from public.lessons
  where id = p_lesson_id and regular_plan_id is not null
    and status in ('scheduled', 'confirmed') and start_at > now()
  for update;
  if not found then raise exception 'Nie znaleziono przyszłej lekcji stałej.' using errcode = 'P0002'; end if;

  select auth_user_id into v_substitute_auth from public.tutors
  where id = p_substitute_tutor_id and status = 'active';
  if not found then raise exception 'Wybierz aktywnego korepetytora.' using errcode = 'P0002'; end if;

  if exists (
    select 1 from public.lessons l
    where l.tutor_id = p_substitute_tutor_id and l.id <> p_lesson_id
      and l.status not in ('cancelled', 'rescheduled')
      and l.start_at is not null and l.end_at is not null
      and tstzrange(l.start_at, l.end_at, '[)') && tstzrange(v_lesson.start_at, v_lesson.end_at, '[)')
  ) then
    raise exception 'Wybrany korepetytor ma wtedy inną lekcję.' using errcode = '23P01';
  end if;

  update public.lessons
  set original_tutor_id = coalesce(original_tutor_id, tutor_id), tutor_id = p_substitute_tutor_id,
      operational_note = 'Zastępstwo: ' || v_reason
  where id = p_lesson_id;
  update public.regular_lesson_occurrences
  set assigned_tutor_id = p_substitute_tutor_id, reason = 'Zastępstwo: ' || v_reason
  where lesson_id = p_lesson_id;

  if v_substitute_auth is not null then
    insert into public.notifications (user_id, type, title, message, lesson_id)
    values (v_substitute_auth, 'regular_lesson_substitution', 'Nowe zastępstwo',
      'Przypisano Ci zastępstwo na stałej lekcji ucznia ' || coalesce(v_lesson.student_name, 'EduSHOT') || '.', p_lesson_id);
  end if;

  insert into public.audit_logs (actor_user_id, actor_email, action, entity_type, entity_id, details)
  values (p_actor_user_id, p_actor_email, 'regular_lesson_substituted', 'lesson', p_lesson_id::text,
    jsonb_build_object('previous_tutor_id', v_lesson.tutor_id, 'substitute_tutor_id', p_substitute_tutor_id, 'reason', v_reason));
end;
$$;

create or replace function public.edushot_regular_plan_lifecycle()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and new.status = 'active' then
    perform public.edushot_generate_regular_plan_lessons(new.id, 90);
  elsif tg_op = 'UPDATE' and old.status = 'active' and new.status = 'ended' then
    update public.lessons
    set status = 'cancelled', cancelled_at = now(), cancellation_tutor_compensation = false,
        policy_note = 'Plan stałych zajęć został zakończony.',
        operational_note = 'Anulowano po zakończeniu planu.'
    where regular_plan_id = new.id and start_at > now() and status in ('scheduled', 'confirmed');
    update public.regular_lesson_occurrences
    set status = 'cancelled', reason = 'Plan stałych zajęć został zakończony.'
    where plan_id = new.id and occurrence_date >= current_date and status = 'scheduled';
  end if;
  return new;
end;
$$;

drop trigger if exists regular_plan_lifecycle on public.regular_lesson_plans;
create trigger regular_plan_lifecycle
after insert or update on public.regular_lesson_plans
for each row execute function public.edushot_regular_plan_lifecycle();

revoke all on function public.edushot_generate_regular_plan_lessons(uuid, integer) from public, anon, authenticated;
revoke all on function public.edushot_generate_all_regular_lessons(integer) from public, anon, authenticated;
revoke all on function public.edushot_admin_add_regular_break(uuid, date, date, text, uuid, text) from public, anon, authenticated;
revoke all on function public.edushot_admin_substitute_regular_lesson(uuid, uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.edushot_regular_plan_lifecycle() from public, anon, authenticated;
grant execute on function public.edushot_generate_regular_plan_lessons(uuid, integer) to service_role;
grant execute on function public.edushot_generate_all_regular_lessons(integer) to service_role;
grant execute on function public.edushot_admin_add_regular_break(uuid, date, date, text, uuid, text) to service_role;
grant execute on function public.edushot_admin_substitute_regular_lesson(uuid, uuid, text, uuid, text) to service_role;
grant execute on function public.edushot_regular_plan_lifecycle() to service_role;

create extension if not exists pg_cron with schema pg_catalog;
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'edushot-generate-regular-lessons-daily';
  perform cron.schedule(
    'edushot-generate-regular-lessons-daily',
    '15 2 * * *',
    'select public.edushot_generate_all_regular_lessons(90);'
  );
end $$;

comment on table public.regular_lesson_occurrences is
  'Każda oczekiwana data z planu stałego, również pominięta lub konfliktowa.';
