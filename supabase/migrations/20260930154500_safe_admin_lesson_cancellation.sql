-- EduSHOT: bezpieczne anulowanie pojedynczej lekcji przez administratora.
-- Historia pozostaje w systemie, a lekcja nie może trafić do wypłaty ani przychodu.

create or replace function public.edushot_admin_cancel_lesson(
  p_lesson_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_actor_email text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lesson public.lessons%rowtype;
  v_reason text := nullif(btrim(p_reason), '');
  v_tutor_auth_user_id uuid;
  v_period_id uuid;
  v_notice_minutes integer;
begin
  if v_reason is null then
    raise exception 'Podaj powód anulowania lekcji.' using errcode = '22023';
  end if;

  select * into v_lesson
  from public.lessons
  where id = p_lesson_id
  for update;

  if not found then
    raise exception 'Nie znaleziono lekcji.' using errcode = 'P0002';
  end if;

  if v_lesson.status = 'cancelled' then
    return jsonb_build_object(
      'lesson_id', v_lesson.id,
      'status', v_lesson.status,
      'already_cancelled', true
    );
  end if;

  if v_lesson.status not in ('scheduled', 'confirmed') then
    raise exception 'Można anulować tylko przyszłą, aktywną lekcję.' using errcode = '55000';
  end if;

  if v_lesson.start_at is not null and v_lesson.start_at <= now() then
    raise exception 'Rozpoczętej lub zakończonej lekcji nie można anulować.' using errcode = '55000';
  end if;

  if coalesce(v_lesson.payout_paid, false)
     or exists (
       select 1
       from public.lesson_finance finance
       where finance.lesson_id = p_lesson_id and finance.payout_paid = true
     )
     or exists (
       select 1
       from public.payout_items item
       join public.payout_periods period on period.id = item.payout_period_id
       where item.lesson_id = p_lesson_id and period.status = 'PAID'
     ) then
    raise exception 'Lekcja jest już objęta zamkniętą wypłatą i nie może zostać anulowana.' using errcode = '55000';
  end if;

  v_notice_minutes := case
    when v_lesson.start_at is null then null
    else greatest(0, floor(extract(epoch from (v_lesson.start_at - now())) / 60)::integer)
  end;

  for v_period_id in
    select distinct item.payout_period_id
    from public.payout_items item
    join public.payout_periods period on period.id = item.payout_period_id
    where item.lesson_id = p_lesson_id and period.status <> 'PAID'
  loop
    delete from public.payout_items
    where lesson_id = p_lesson_id and payout_period_id = v_period_id;
    perform public.edushot_recalculate_payout_period(v_period_id);
  end loop;

  update public.lessons
  set status = 'cancelled',
      cancelled_at = now(),
      cancellation_notice_minutes = v_notice_minutes,
      cancellation_refund_eligible = true,
      cancellation_tutor_compensation = false,
      policy_note = 'Anulowane przez administratora: ' || v_reason,
      operational_note = 'Anulowane przez administratora: ' || v_reason
  where id = p_lesson_id;

  update public.regular_lesson_occurrences
  set status = 'cancelled', reason = 'Anulowane przez administratora: ' || v_reason
  where lesson_id = p_lesson_id;

  select tutor.auth_user_id into v_tutor_auth_user_id
  from public.tutors tutor
  where tutor.id = v_lesson.tutor_id;

  if v_tutor_auth_user_id is not null then
    insert into public.notifications (user_id, type, title, message, lesson_id)
    values (
      v_tutor_auth_user_id,
      'lesson_cancelled_admin',
      'Lekcja została anulowana',
      'Administrator anulował lekcję ucznia ' || coalesce(v_lesson.student_name, 'EduSHOT') || '. Powód: ' || v_reason,
      p_lesson_id
    ) on conflict do nothing;
  end if;

  insert into public.audit_logs (
    actor_user_id, actor_email, action, entity_type, entity_id, details
  ) values (
    p_actor_user_id,
    p_actor_email,
    'lesson_cancelled_by_admin',
    'lesson',
    p_lesson_id::text,
    jsonb_build_object(
      'reason', v_reason,
      'provider', v_lesson.provider,
      'provider_booking_id', v_lesson.provider_booking_id,
      'regular_plan_id', v_lesson.regular_plan_id,
      'tutor_id', v_lesson.tutor_id
    )
  );

  return jsonb_build_object(
    'lesson_id', p_lesson_id,
    'status', 'cancelled',
    'tutor_id', v_lesson.tutor_id,
    'regular_plan_id', v_lesson.regular_plan_id,
    'removed_from_payout', true
  );
end;
$$;

revoke all on function public.edushot_admin_cancel_lesson(uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.edushot_admin_cancel_lesson(uuid, text, uuid, text)
  to service_role;

comment on function public.edushot_admin_cancel_lesson(uuid, text, uuid, text) is
  'Anuluje przyszłą lekcję bez kasowania historii, wyklucza ją z otwartych rozliczeń i powiadamia korepetytora.';
