create or replace function public.submit_lesson_outcome(
  p_lesson_id uuid,
  p_attendance text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lesson public.lessons%rowtype;
  v_tutor_user_id uuid;
  v_user_id uuid := (select auth.uid());
  v_is_admin boolean := (select public.is_admin());
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_attendance not in ('held', 'late', 'no_show') then
    raise exception 'Invalid lesson outcome' using errcode = '22023';
  end if;

  select l.*
  into v_lesson
  from public.lessons l
  where l.id = p_lesson_id
  for update;

  if not found then
    raise exception 'Lesson not found' using errcode = 'P0002';
  end if;

  select t.auth_user_id
  into v_tutor_user_id
  from public.tutors t
  where t.id = v_lesson.tutor_id;

  if not v_is_admin and v_tutor_user_id is distinct from v_user_id then
    raise exception 'Not allowed to update this lesson' using errcode = '42501';
  end if;

  if not v_is_admin and (v_lesson.start_at is null or now() < v_lesson.start_at) then
    raise exception 'Lesson outcome can be submitted only after the lesson starts'
      using errcode = '22023';
  end if;

  if v_lesson.status not in ('scheduled', 'confirmed') then
    if v_lesson.status = 'completed' and v_lesson.attendance = p_attendance then
      return jsonb_build_object(
        'id', v_lesson.id,
        'status', v_lesson.status,
        'attendance', v_lesson.attendance,
        'updated_at', v_lesson.updated_at
      );
    end if;

    raise exception 'Lesson outcome is already final' using errcode = '22023';
  end if;

  update public.lessons
  set status = 'completed',
      attendance = p_attendance,
      updated_at = now()
  where id = p_lesson_id
  returning * into v_lesson;

  return jsonb_build_object(
    'id', v_lesson.id,
    'status', v_lesson.status,
    'attendance', v_lesson.attendance,
    'updated_at', v_lesson.updated_at
  );
end;
$$;

revoke all on function public.submit_lesson_outcome(uuid, text)
  from public, anon;
grant execute on function public.submit_lesson_outcome(uuid, text)
  to authenticated, service_role;

