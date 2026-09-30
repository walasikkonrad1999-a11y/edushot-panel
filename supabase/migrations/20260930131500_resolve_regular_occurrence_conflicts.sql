-- EduSHOT: bezpieczne przypisanie zastępstwa również dla konfliktu,
-- dla którego lekcja nie została jeszcze zmaterializowana.

create or replace function public.edushot_admin_substitute_regular_occurrence(
  p_occurrence_id uuid,
  p_substitute_tutor_id uuid,
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
  v_occurrence public.regular_lesson_occurrences%rowtype;
  v_plan public.regular_lesson_plans%rowtype;
  v_student public.students%rowtype;
  v_substitute public.tutors%rowtype;
  v_guardian_email text;
  v_lesson_id uuid;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_reason is null then
    raise exception 'Podaj powód zastępstwa.' using errcode = '22023';
  end if;

  select * into v_occurrence
  from public.regular_lesson_occurrences
  where id = p_occurrence_id
    and status = 'conflict'
    and planned_start_at > now()
  for update;
  if not found then
    raise exception 'Nie znaleziono przyszłego konfliktu wymagającego zastępstwa.' using errcode = 'P0002';
  end if;

  select * into v_plan
  from public.regular_lesson_plans
  where id = v_occurrence.plan_id and status = 'active';
  if not found then
    raise exception 'Plan zajęć nie jest aktywny.' using errcode = 'P0002';
  end if;

  select * into v_student
  from public.students
  where id = v_plan.student_id and status = 'active';
  if not found then
    raise exception 'Uczeń nie jest aktywny.' using errcode = 'P0002';
  end if;

  select * into v_substitute
  from public.tutors
  where id = p_substitute_tutor_id and status = 'active';
  if not found then
    raise exception 'Wybierz aktywnego korepetytora.' using errcode = 'P0002';
  end if;
  if p_substitute_tutor_id = v_occurrence.original_tutor_id then
    raise exception 'Wybierz innego korepetytora na zastępstwo.' using errcode = '22023';
  end if;

  if exists (
    select 1 from public.tutor_time_off time_off
    where time_off.tutor_id = p_substitute_tutor_id
      and v_occurrence.occurrence_date between time_off.date_from and time_off.date_to
  ) then
    raise exception 'Wybrany korepetytor jest tego dnia nieobecny.' using errcode = '23P01';
  end if;

  if exists (
    select 1 from public.lessons lesson
    where lesson.tutor_id = p_substitute_tutor_id
      and lesson.id is distinct from v_occurrence.lesson_id
      and lesson.status not in ('cancelled', 'rescheduled')
      and lesson.start_at is not null and lesson.end_at is not null
      and tstzrange(lesson.start_at, lesson.end_at, '[)')
          && tstzrange(v_occurrence.planned_start_at, v_occurrence.planned_end_at, '[)')
  ) then
    raise exception 'Wybrany korepetytor ma wtedy inną lekcję.' using errcode = '23P01';
  end if;

  if v_occurrence.lesson_id is not null then
    update public.lessons
    set original_tutor_id = coalesce(original_tutor_id, tutor_id),
        tutor_id = p_substitute_tutor_id,
        operational_note = 'Zastępstwo: ' || v_reason
    where id = v_occurrence.lesson_id
      and regular_plan_id = v_occurrence.plan_id
      and status in ('scheduled', 'confirmed')
    returning id into v_lesson_id;

    if v_lesson_id is null then
      raise exception 'Powiązana lekcja nie może już otrzymać zastępstwa.' using errcode = 'P0002';
    end if;
  else
    select guardian.email into v_guardian_email
    from public.student_guardians link
    join public.guardians guardian on guardian.id = link.guardian_id
    where link.student_id = v_student.id and link.is_primary
    limit 1;

    insert into public.lessons (
      tutor_id, student_id, student_name, student_email, subject, level,
      rate, lesson_date, time_start, time_end, meet_url, status,
      start_at, end_at, duration_minutes, timezone, provider, pricing_tier,
      regular_plan_id, original_tutor_id, operational_note
    ) values (
      p_substitute_tutor_id, v_student.id, v_student.name, v_guardian_email,
      v_plan.subject, v_plan.level,
      case v_plan.pricing_tier when 'primary_school' then 35 when 'secondary_basic' then 40 else 45 end,
      v_occurrence.occurrence_date,
      to_char(v_occurrence.planned_start_at at time zone v_plan.timezone, 'HH24:MI'),
      to_char(v_occurrence.planned_end_at at time zone v_plan.timezone, 'HH24:MI'),
      v_plan.meet_url, 'scheduled', v_occurrence.planned_start_at,
      v_occurrence.planned_end_at, v_plan.duration_minutes, v_plan.timezone,
      'edushot_regular', v_plan.pricing_tier, v_plan.id,
      v_occurrence.original_tutor_id, 'Zastępstwo: ' || v_reason
    ) returning id into v_lesson_id;
  end if;

  update public.regular_lesson_occurrences
  set lesson_id = v_lesson_id,
      assigned_tutor_id = p_substitute_tutor_id,
      status = 'scheduled',
      reason = 'Zastępstwo: ' || v_reason
  where id = p_occurrence_id;

  if v_substitute.auth_user_id is not null then
    insert into public.notifications (user_id, type, title, message, lesson_id)
    values (
      v_substitute.auth_user_id,
      'regular_lesson_substitution',
      'Nowe zastępstwo',
      'Przypisano Ci zastępstwo na stałej lekcji ucznia ' || coalesce(v_student.name, 'EduSHOT') || '.',
      v_lesson_id
    );
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_email, action, entity_type, entity_id, details
  ) values (
    p_actor_user_id, p_actor_email, 'regular_occurrence_substituted',
    'regular_lesson_occurrence', p_occurrence_id::text,
    jsonb_build_object(
      'lesson_id', v_lesson_id,
      'original_tutor_id', v_occurrence.original_tutor_id,
      'substitute_tutor_id', p_substitute_tutor_id,
      'reason', v_reason
    )
  );

  return v_lesson_id;
end;
$$;

revoke all on function public.edushot_admin_substitute_regular_occurrence(uuid, uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.edushot_admin_substitute_regular_occurrence(uuid, uuid, text, uuid, text)
  to service_role;

comment on function public.edushot_admin_substitute_regular_occurrence(uuid, uuid, text, uuid, text) is
  'Rozwiązuje przyszły konflikt planu stałego, materializuje brakującą lekcję i przypisuje zastępstwo.';
