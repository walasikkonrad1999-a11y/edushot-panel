-- Stałe lekcje działają niezależnie od dostępności Cal.com.
-- Cal.com pozostaje automatycznie zarządzany wyłącznie dla nieobecności.
-- Kolizje są materializowane jako dwie widoczne lekcje i wymagają decyzji admina.

alter table public.tutors
  add column if not exists cal_regular_overrides_released_at timestamptz;

update public.tutors tutor
set cal_regular_overrides_released_at = now()
where tutor.cal_regular_overrides_released_at is null
  and not exists (
    select 1
    from public.lessons lesson
    where lesson.tutor_id = tutor.id
      and lesson.regular_plan_id is not null
      and lesson.start_at > now()
      and lesson.status in ('scheduled', 'confirmed')
  );

alter table public.tutors
  alter column cal_regular_overrides_released_at set default now();

comment on column public.tutors.cal_regular_overrides_released_at is
  'Znacznik jednorazowego usunięcia dawnych blokad stałych lekcji z Cal.com.';

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
  v_materialize boolean;
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

  select guardian.email into v_guardian_email
  from public.student_guardians link
  join public.guardians guardian on guardian.id = link.guardian_id
  where link.student_id = v_student.id and link.is_primary
  limit 1;

  for v_day in
    select day::date
    from generate_series(
      greatest(v_plan.starts_on, current_date)::timestamp,
      least(coalesce(v_plan.ends_on, current_date + p_horizon_days), current_date + p_horizon_days)::timestamp,
      interval '1 day'
    ) day
    where extract(isodow from day)::integer = v_plan.weekday
      and (
        v_plan.frequency = 'weekly'
        or mod((day::date - v_plan.starts_on), 14) = 0
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
    v_materialize := true;

    if exists (
      select 1 from public.regular_plan_breaks break_item
      where break_item.plan_id = v_plan.id
        and v_day between break_item.date_from and break_item.date_to
    ) then
      v_status := 'skipped_break';
      v_materialize := false;
      select break_item.reason into v_reason
      from public.regular_plan_breaks break_item
      where break_item.plan_id = v_plan.id
        and v_day between break_item.date_from and break_item.date_to
      order by break_item.created_at desc
      limit 1;
      v_skipped := v_skipped + 1;
    elsif exists (
      select 1 from public.tutor_time_off absence
      where absence.tutor_id = v_plan.tutor_id
        and v_day between absence.date_from and absence.date_to
    ) then
      v_status := 'conflict';
      v_materialize := false;
      select 'Nieobecność korepetytora: ' || coalesce(absence.reason, 'wymagane zastępstwo')
        into v_reason
      from public.tutor_time_off absence
      where absence.tutor_id = v_plan.tutor_id
        and v_day between absence.date_from and absence.date_to
      order by absence.created_at desc
      limit 1;
      v_conflicts := v_conflicts + 1;
    elsif exists (
      select 1 from public.lessons lesson
      where lesson.tutor_id = v_plan.tutor_id
        and lesson.status not in ('cancelled', 'rescheduled')
        and lesson.start_at is not null
        and lesson.end_at is not null
        and tstzrange(lesson.start_at, lesson.end_at, '[)')
            && tstzrange(v_start, v_end, '[)')
    ) then
      v_status := 'conflict';
      v_reason := 'Dwie lekcje w tym samym czasie — anuluj jedną albo ustaw zastępstwo.';
      v_conflicts := v_conflicts + 1;
    end if;

    if v_materialize then
      insert into public.lessons (
        tutor_id, student_id, student_name, student_email, subject, level,
        rate, lesson_date, time_start, time_end, meet_url, status,
        start_at, end_at, duration_minutes, timezone, provider, pricing_tier,
        regular_plan_id, original_tutor_id, operational_note
      ) values (
        v_plan.tutor_id, v_student.id, v_student.name, v_guardian_email,
        v_plan.subject, v_plan.level,
        case v_plan.pricing_tier
          when 'primary_school' then 35
          when 'secondary_basic' then 40
          else 45
        end,
        v_day,
        to_char(v_start at time zone v_plan.timezone, 'HH24:MI'),
        to_char(v_end at time zone v_plan.timezone, 'HH24:MI'),
        v_plan.meet_url, 'scheduled', v_start, v_end, v_plan.duration_minutes,
        v_plan.timezone, 'edushot_regular', v_plan.pricing_tier,
        v_plan.id, v_plan.tutor_id,
        case when v_status = 'conflict'
          then v_reason
          else 'Lekcja wygenerowana z planu stałego.'
        end
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
    'plan_id', v_plan.id,
    'created', v_created,
    'existing', v_existing,
    'skipped', v_skipped,
    'conflicts', v_conflicts
  );
end;
$$;

-- Istniejące nieobecności stają się zadaniami do ustawienia zastępstwa.
update public.regular_lesson_occurrences occurrence
set status = 'conflict',
    reason = case
      when coalesce(occurrence.reason, '') ilike 'Nieobecność korepetytora:%'
        then occurrence.reason
      else 'Nieobecność korepetytora: ' || coalesce(occurrence.reason, 'wymagane zastępstwo')
    end
where occurrence.status = 'skipped_time_off'
  and occurrence.planned_start_at > now();

-- Stare konflikty nie miały lekcji. Materializujemy je, żeby administrator
-- mógł anulować dokładnie jedną z nakładających się pozycji.
do $$
declare
  item record;
  v_lesson_id uuid;
begin
  for item in
    select occurrence.*, plan.student_id, plan.subject, plan.level,
           plan.pricing_tier, plan.duration_minutes, plan.timezone,
           plan.meet_url, student.name as student_name,
           (
             select guardian.email
             from public.student_guardians link
             join public.guardians guardian on guardian.id = link.guardian_id
             where link.student_id = plan.student_id and link.is_primary
             limit 1
           ) as guardian_email
    from public.regular_lesson_occurrences occurrence
    join public.regular_lesson_plans plan on plan.id = occurrence.plan_id
    join public.students student on student.id = plan.student_id
    where occurrence.status = 'conflict'
      and occurrence.lesson_id is null
      and occurrence.planned_start_at > now()
      and coalesce(occurrence.reason, '') not ilike 'Nieobecność korepetytora:%'
  loop
    insert into public.lessons (
      tutor_id, student_id, student_name, student_email, subject, level,
      rate, lesson_date, time_start, time_end, meet_url, status,
      start_at, end_at, duration_minutes, timezone, provider, pricing_tier,
      regular_plan_id, original_tutor_id, operational_note
    ) values (
      item.assigned_tutor_id, item.student_id, item.student_name,
      item.guardian_email, item.subject, item.level,
      case item.pricing_tier
        when 'primary_school' then 35
        when 'secondary_basic' then 40
        else 45
      end,
      item.occurrence_date,
      to_char(item.planned_start_at at time zone item.timezone, 'HH24:MI'),
      to_char(item.planned_end_at at time zone item.timezone, 'HH24:MI'),
      item.meet_url, 'scheduled', item.planned_start_at,
      item.planned_end_at, item.duration_minutes, item.timezone,
      'edushot_regular', item.pricing_tier, item.plan_id,
      item.original_tutor_id,
      'Dwie lekcje w tym samym czasie — anuluj jedną albo ustaw zastępstwo.'
    ) returning id into v_lesson_id;

    update public.regular_lesson_occurrences
    set lesson_id = v_lesson_id,
        reason = 'Dwie lekcje w tym samym czasie — anuluj jedną albo ustaw zastępstwo.'
    where id = item.id;
  end loop;
end;
$$;

revoke all on function public.edushot_generate_regular_plan_lessons(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.edushot_generate_regular_plan_lessons(uuid, integer)
  to service_role;

comment on function public.edushot_generate_regular_plan_lessons(uuid, integer) is
  'Generuje stałe lekcje niezależnie od Cal.com; kolizje pozostawia widoczne do decyzji administratora.';
