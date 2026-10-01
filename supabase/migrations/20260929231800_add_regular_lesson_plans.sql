-- EduSHOT: niezależne od Cal.com plany zajęć dla stałych uczniów.
-- Każda zmiana tworzy nową wersję planu, dzięki czemu historia pozostaje kompletna.

create table if not exists public.regular_lesson_plans (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete restrict,
  tutor_id uuid not null references public.tutors(id) on delete restrict,
  subject text not null,
  level text not null,
  pricing_tier text not null,
  duration_minutes integer not null,
  weekday integer not null,
  start_time time without time zone not null,
  frequency text not null default 'weekly',
  timezone text not null default 'Europe/Warsaw',
  meet_url text not null,
  starts_on date not null,
  ends_on date,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint regular_lesson_plans_subject_not_blank check (btrim(subject) <> ''),
  constraint regular_lesson_plans_level_not_blank check (btrim(level) <> ''),
  constraint regular_lesson_plans_pricing_tier_check
    check (pricing_tier in ('primary_school', 'secondary_basic', 'secondary_extended')),
  constraint regular_lesson_plans_duration_check check (duration_minutes in (30, 60, 90)),
  constraint regular_lesson_plans_weekday_check check (weekday between 1 and 7),
  constraint regular_lesson_plans_frequency_check check (frequency in ('weekly', 'biweekly')),
  constraint regular_lesson_plans_status_check check (status in ('active', 'ended')),
  constraint regular_lesson_plans_dates_check check (ends_on is null or ends_on >= starts_on),
  constraint regular_lesson_plans_active_end_check check (
    (status = 'active' and ends_on is null)
    or (status = 'ended' and ends_on is not null)
  ),
  constraint regular_lesson_plans_meet_url_check check (
    meet_url ~* '^https://meet\\.google\\.com/[a-z0-9-]+([/?#].*)?$'
  )
);

create unique index if not exists regular_lesson_plans_one_active_student_uidx
  on public.regular_lesson_plans (student_id)
  where status = 'active';
create index if not exists regular_lesson_plans_tutor_status_idx
  on public.regular_lesson_plans (tutor_id, status);
create index if not exists regular_lesson_plans_schedule_idx
  on public.regular_lesson_plans (weekday, start_time)
  where status = 'active';

drop trigger if exists regular_lesson_plans_updated_at on public.regular_lesson_plans;
create trigger regular_lesson_plans_updated_at
before update on public.regular_lesson_plans
for each row execute function public.set_updated_at();

alter table public.regular_lesson_plans enable row level security;

create policy regular_lesson_plans_admin_all
on public.regular_lesson_plans
for all
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

create policy regular_lesson_plans_tutor_select
on public.regular_lesson_plans
for select
to authenticated
using (
  exists (
    select 1 from public.tutors t
    where t.id = tutor_id
      and t.auth_user_id = (select auth.uid())
      and t.status = 'active'
  )
);

create policy students_assigned_tutor_select
on public.students
for select
to authenticated
using (
  exists (
    select 1
    from public.regular_lesson_plans p
    join public.tutors t on t.id = p.tutor_id
    where p.student_id = students.id
      and p.status = 'active'
      and t.auth_user_id = (select auth.uid())
      and t.status = 'active'
  )
);

revoke all on table public.regular_lesson_plans from public, anon;
grant select, insert, update on table public.regular_lesson_plans to authenticated;
grant select, insert, update, delete on table public.regular_lesson_plans to service_role;

create or replace function public.edushot_admin_replace_regular_lesson_plan(
  p_student_id uuid,
  p_tutor_id uuid,
  p_subject text,
  p_level text,
  p_pricing_tier text,
  p_duration_minutes integer,
  p_weekday integer,
  p_start_time time,
  p_frequency text,
  p_timezone text,
  p_meet_url text,
  p_starts_on date,
  p_actor_user_id uuid,
  p_actor_email text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_id uuid;
  v_subject text := nullif(btrim(p_subject), '');
  v_level text := nullif(btrim(p_level), '');
  v_timezone text := coalesce(nullif(btrim(p_timezone), ''), 'Europe/Warsaw');
  v_meet_url text := lower(nullif(btrim(p_meet_url), ''));
  v_starts_on date := coalesce(p_starts_on, current_date);
begin
  if v_subject is null or v_level is null then
    raise exception 'Uzupełnij przedmiot i poziom.' using errcode = '22023';
  end if;
  if p_pricing_tier not in ('primary_school', 'secondary_basic', 'secondary_extended') then
    raise exception 'Wybierz prawidłowy poziom rozliczeniowy.' using errcode = '22023';
  end if;
  if p_duration_minutes not in (30, 60, 90) then
    raise exception 'Długość zajęć musi wynosić 30, 60 albo 90 minut.' using errcode = '22023';
  end if;
  if p_weekday not between 1 and 7 then
    raise exception 'Wybierz prawidłowy dzień tygodnia.' using errcode = '22023';
  end if;
  if p_frequency not in ('weekly', 'biweekly') then
    raise exception 'Wybierz prawidłową częstotliwość.' using errcode = '22023';
  end if;
  if v_meet_url is null or v_meet_url !~* '^https://meet\\.google\\.com/[a-z0-9-]+([/?#].*)?$' then
    raise exception 'Podaj prawidłowy stały link Google Meet.' using errcode = '22023';
  end if;

  perform 1 from public.students
  where id = p_student_id and student_kind = 'regular' and status = 'active'
  for update;
  if not found then
    raise exception 'Plan można przypisać tylko aktywnemu stałemu uczniowi.' using errcode = 'P0002';
  end if;

  perform 1 from public.tutors
  where id = p_tutor_id and status = 'active'
  for update;
  if not found then
    raise exception 'Wybierz aktywnego korepetytora.' using errcode = 'P0002';
  end if;

  update public.regular_lesson_plans
  set status = 'ended', ends_on = greatest(v_starts_on - 1, starts_on)
  where student_id = p_student_id and status = 'active';

  insert into public.regular_lesson_plans (
    student_id, tutor_id, subject, level, pricing_tier, duration_minutes,
    weekday, start_time, frequency, timezone, meet_url, starts_on
  ) values (
    p_student_id, p_tutor_id, v_subject, v_level, p_pricing_tier, p_duration_minutes,
    p_weekday, p_start_time, p_frequency, v_timezone, v_meet_url, v_starts_on
  ) returning id into v_plan_id;

  insert into public.audit_logs (
    actor_user_id, actor_email, action, entity_type, entity_id, details
  ) values (
    p_actor_user_id, p_actor_email, 'regular_lesson_plan_replaced',
    'regular_lesson_plan', v_plan_id::text,
    jsonb_build_object(
      'student_id', p_student_id, 'tutor_id', p_tutor_id,
      'weekday', p_weekday, 'start_time', p_start_time,
      'frequency', p_frequency, 'starts_on', v_starts_on
    )
  );

  return v_plan_id;
end;
$$;

create or replace function public.edushot_admin_end_regular_lesson_plan(
  p_student_id uuid,
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
  v_reason text := nullif(btrim(p_reason), '');
  v_plan_id uuid;
begin
  if v_reason is null then
    raise exception 'Podaj powód zakończenia planu.' using errcode = '22023';
  end if;

  update public.regular_lesson_plans
  set status = 'ended', ends_on = greatest(current_date, starts_on)
  where student_id = p_student_id and status = 'active'
  returning id into v_plan_id;
  if v_plan_id is null then
    raise exception 'Uczeń nie ma aktywnego planu.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_email, action, entity_type, entity_id, details
  ) values (
    p_actor_user_id, p_actor_email, 'regular_lesson_plan_ended',
    'regular_lesson_plan', v_plan_id::text,
    jsonb_build_object('student_id', p_student_id, 'reason', v_reason)
  );
end;
$$;

-- Zakończenie współpracy automatycznie zamyka aktywny plan, ale go nie usuwa.
create or replace function public.edushot_close_plan_when_student_ends()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.student_kind = 'regular' and new.status = 'ended' and old.status is distinct from new.status then
    update public.regular_lesson_plans
    set status = 'ended', ends_on = greatest(coalesce(new.ended_on, current_date), starts_on)
    where student_id = new.id and status = 'active';
  end if;
  return new;
end;
$$;

drop trigger if exists students_close_regular_plan on public.students;
create trigger students_close_regular_plan
after update of status on public.students
for each row execute function public.edushot_close_plan_when_student_ends();

revoke all on function public.edushot_admin_replace_regular_lesson_plan(
  uuid, uuid, text, text, text, integer, integer, time, text, text, text, date, uuid, text
) from public, anon, authenticated;
revoke all on function public.edushot_admin_end_regular_lesson_plan(
  uuid, text, uuid, text
) from public, anon, authenticated;
revoke all on function public.edushot_close_plan_when_student_ends()
from public, anon, authenticated;

grant execute on function public.edushot_admin_replace_regular_lesson_plan(
  uuid, uuid, text, text, text, integer, integer, time, text, text, text, date, uuid, text
) to service_role;
grant execute on function public.edushot_admin_end_regular_lesson_plan(
  uuid, text, uuid, text
) to service_role;
grant execute on function public.edushot_close_plan_when_student_ends()
to service_role;

comment on table public.regular_lesson_plans is
  'Wersjonowane plany stałych zajęć EduSHOT, niezależne od rezerwacji i webhooków Cal.com.';
