-- EduSHOT: transakcyjne operacje administracyjne na stałych uczniach.
-- Funkcje są dostępne wyłącznie dla backendu z rolą service_role.

create or replace function public.edushot_admin_create_regular_student(
  p_student_name text,
  p_guardian_name text,
  p_guardian_email text,
  p_guardian_phone text,
  p_started_on date,
  p_actor_user_id uuid,
  p_actor_email text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id uuid;
  v_guardian_id uuid;
  v_student_name text := nullif(btrim(p_student_name), '');
  v_guardian_name text := nullif(btrim(p_guardian_name), '');
  v_email text := lower(nullif(btrim(p_guardian_email), ''));
  v_phone text := nullif(btrim(p_guardian_phone), '');
begin
  if v_student_name is null then
    raise exception 'Podaj imię i nazwisko ucznia.' using errcode = '22023';
  end if;
  if v_guardian_name is null then
    raise exception 'Podaj imię i nazwisko rodzica lub opiekuna.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Podaj e-mail lub telefon rodzica.' using errcode = '22023';
  end if;

  select g.id into v_guardian_id
  from public.guardians g
  where (v_email is not null and lower(g.email) = v_email)
     or (v_email is null and v_phone is not null and g.phone = v_phone)
  order by g.created_at
  limit 1
  for update;

  if v_guardian_id is null then
    insert into public.guardians (name, email, phone)
    values (v_guardian_name, v_email, v_phone)
    returning id into v_guardian_id;
  else
    update public.guardians
    set name = v_guardian_name,
        email = coalesce(v_email, email),
        phone = coalesce(v_phone, phone)
    where id = v_guardian_id;
  end if;

  insert into public.students (
    name, student_kind, status, started_on, ended_on, end_reason
  ) values (
    v_student_name, 'regular', 'active',
    coalesce(p_started_on, current_date), null, null
  )
  returning id into v_student_id;

  insert into public.student_guardians (
    student_id, guardian_id, relationship, is_primary
  ) values (
    v_student_id, v_guardian_id, 'parent', true
  );

  insert into public.audit_logs (
    actor_user_id, actor_email, action, entity_type, entity_id, details
  ) values (
    p_actor_user_id, p_actor_email, 'regular_student_created',
    'student', v_student_id::text,
    jsonb_build_object(
      'student_name', v_student_name,
      'guardian_id', v_guardian_id,
      'started_on', coalesce(p_started_on, current_date)
    )
  );

  return v_student_id;
end;
$$;

create or replace function public.edushot_admin_update_regular_student(
  p_student_id uuid,
  p_student_name text,
  p_guardian_name text,
  p_guardian_email text,
  p_guardian_phone text,
  p_started_on date,
  p_actor_user_id uuid,
  p_actor_email text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_guardian_id uuid;
  v_student_name text := nullif(btrim(p_student_name), '');
  v_guardian_name text := nullif(btrim(p_guardian_name), '');
  v_email text := lower(nullif(btrim(p_guardian_email), ''));
  v_phone text := nullif(btrim(p_guardian_phone), '');
begin
  if v_student_name is null or v_guardian_name is null then
    raise exception 'Uzupełnij dane ucznia i rodzica.' using errcode = '22023';
  end if;
  if v_email is null and v_phone is null then
    raise exception 'Podaj e-mail lub telefon rodzica.' using errcode = '22023';
  end if;

  perform 1
  from public.students
  where id = p_student_id and student_kind = 'regular'
  for update;
  if not found then
    raise exception 'Nie znaleziono stałego ucznia.' using errcode = 'P0002';
  end if;

  select sg.guardian_id into v_guardian_id
  from public.student_guardians sg
  where sg.student_id = p_student_id and sg.is_primary
  limit 1
  for update;
  if v_guardian_id is null then
    raise exception 'Brak rodzica przypisanego do ucznia.' using errcode = 'P0002';
  end if;

  update public.guardians
  set name = v_guardian_name, email = v_email, phone = v_phone
  where id = v_guardian_id;

  update public.students
  set name = v_student_name,
      started_on = coalesce(p_started_on, started_on)
  where id = p_student_id;

  insert into public.audit_logs (
    actor_user_id, actor_email, action, entity_type, entity_id, details
  ) values (
    p_actor_user_id, p_actor_email, 'regular_student_updated',
    'student', p_student_id::text,
    jsonb_build_object('guardian_id', v_guardian_id)
  );
end;
$$;

create or replace function public.edushot_admin_set_regular_student_status(
  p_student_id uuid,
  p_status text,
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
begin
  if p_status not in ('active', 'ended') then
    raise exception 'Nieprawidłowy status ucznia.' using errcode = '22023';
  end if;
  if p_status = 'ended' and v_reason is null then
    raise exception 'Podaj powód zakończenia współpracy.' using errcode = '22023';
  end if;

  update public.students
  set status = p_status,
      ended_on = case when p_status = 'ended' then current_date else null end,
      end_reason = case when p_status = 'ended' then v_reason else null end
  where id = p_student_id and student_kind = 'regular';
  if not found then
    raise exception 'Nie znaleziono stałego ucznia.' using errcode = 'P0002';
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_email, action, entity_type, entity_id, details
  ) values (
    p_actor_user_id,
    p_actor_email,
    case when p_status = 'ended'
      then 'regular_student_ended'
      else 'regular_student_reactivated'
    end,
    'student',
    p_student_id::text,
    jsonb_build_object('status', p_status, 'reason', v_reason)
  );
end;
$$;

revoke all on function public.edushot_admin_create_regular_student(
  text, text, text, text, date, uuid, text
) from public, anon, authenticated;
revoke all on function public.edushot_admin_update_regular_student(
  uuid, text, text, text, text, date, uuid, text
) from public, anon, authenticated;
revoke all on function public.edushot_admin_set_regular_student_status(
  uuid, text, text, uuid, text
) from public, anon, authenticated;

grant execute on function public.edushot_admin_create_regular_student(
  text, text, text, text, date, uuid, text
) to service_role;
grant execute on function public.edushot_admin_update_regular_student(
  uuid, text, text, text, text, date, uuid, text
) to service_role;
grant execute on function public.edushot_admin_set_regular_student_status(
  uuid, text, text, uuid, text
) to service_role;
