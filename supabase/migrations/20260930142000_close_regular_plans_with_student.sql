-- Zakończenie współpracy ze stałym uczniem domyka także jego aktywne plany.
-- Historia pozostaje zachowana, a istniejący trigger planu anuluje przyszłe lekcje.

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
  v_closed_plans integer := 0;
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

  if p_status = 'ended' then
    update public.regular_lesson_plans
    set status = 'ended',
        ends_on = current_date,
        updated_at = now()
    where student_id = p_student_id
      and status = 'active';
    get diagnostics v_closed_plans = row_count;
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
    jsonb_build_object(
      'status', p_status,
      'reason', v_reason,
      'closed_plans', v_closed_plans
    )
  );
end;
$$;

revoke all on function public.edushot_admin_set_regular_student_status(
  uuid, text, text, uuid, text
) from public, anon, authenticated;

grant execute on function public.edushot_admin_set_regular_student_status(
  uuid, text, text, uuid, text
) to service_role;
