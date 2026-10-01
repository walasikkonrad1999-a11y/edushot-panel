-- Poprawka walidacji stałego linku Google Meet po wdrożeniu tabeli planów.

alter table public.regular_lesson_plans
  drop constraint if exists regular_lesson_plans_meet_url_check;
alter table public.regular_lesson_plans
  add constraint regular_lesson_plans_meet_url_check check (
    meet_url ~* '^https://meet[.]google[.]com/[a-z0-9-]+([/?#].*)?$'
  );

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
  if v_meet_url is null or v_meet_url !~* '^https://meet[.]google[.]com/[a-z0-9-]+([/?#].*)?$' then
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

revoke all on function public.edushot_admin_replace_regular_lesson_plan(
  uuid, uuid, text, text, text, integer, integer, time, text, text, text, date, uuid, text
) from public, anon, authenticated;
grant execute on function public.edushot_admin_replace_regular_lesson_plan(
  uuid, uuid, text, text, text, integer, integer, time, text, text, text, date, uuid, text
) to service_role;
