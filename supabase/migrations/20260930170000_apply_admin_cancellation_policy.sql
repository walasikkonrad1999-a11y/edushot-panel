-- EduSHOT: administrator może anulować pojedynczą lekcję w imieniu klienta.
-- Rozliczenie korzysta z tej samej polityki co webhook Cal.com:
-- >= próg anulowania: tutor 0 zł; < próg: pełne wynagrodzenie tutora.

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
  v_period_status text;
  v_notice_minutes integer;
  v_cancellation_hours integer := 24;
  v_is_late boolean;
  v_target_status text;
  v_tutor_rate numeric(10,2);
  v_period_start date;
  v_period_end date;
  v_due_date date;
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

  -- Stan mógł zostać zmieniony chwilę wcześniej przez webhook Cal.com.
  -- W takim przypadku nadal normalizujemy wynik według jednej polityki 24 h.
  if v_lesson.status not in ('scheduled', 'confirmed', 'cancelled', 'cancelled_late') then
    raise exception 'Można anulować tylko przyszłą, aktywną lekcję.' using errcode = '55000';
  end if;

  if v_lesson.start_at is null then
    raise exception 'Lekcja nie ma poprawnej daty rozpoczęcia.' using errcode = '55000';
  end if;

  if v_lesson.start_at <= now() then
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

  select coalesce(policy.cancellation_hours, 24)
    into v_cancellation_hours
  from public.booking_policy policy
  order by policy.updated_at desc nulls last
  limit 1;

  v_cancellation_hours := coalesce(v_cancellation_hours, 24);
  v_notice_minutes := greatest(
    0,
    floor(extract(epoch from (v_lesson.start_at - now())) / 60)::integer
  );
  v_is_late := v_notice_minutes < v_cancellation_hours * 60;
  v_target_status := case when v_is_late then 'cancelled_late' else 'cancelled' end;

  update public.lessons
  set status = v_target_status,
      cancelled_at = now(),
      cancellation_notice_minutes = v_notice_minutes,
      cancellation_refund_eligible = not v_is_late,
      cancellation_tutor_compensation = v_is_late,
      policy_violation = false,
      policy_note = case
        when v_is_late then
          'Anulowane przez administratora mniej niż ' || v_cancellation_hours ||
          ' h przed startem — pełna stawka dla korepetytora. Powód: ' || v_reason
        else
          'Anulowane przez administratora co najmniej ' || v_cancellation_hours ||
          ' h przed startem — bez naliczenia dla korepetytora. Powód: ' || v_reason
      end,
      operational_note = 'Anulowane przez administratora: ' || v_reason
  where id = p_lesson_id;

  update public.regular_lesson_occurrences
  set status = 'cancelled', reason = 'Anulowane przez administratora: ' || v_reason
  where lesson_id = p_lesson_id;

  if v_is_late then
    -- Trigger finansowy utworzył lub zaktualizował snapshot po zmianie lekcji.
    select finance.tutor_rate into v_tutor_rate
    from public.lesson_finance finance
    where finance.lesson_id = p_lesson_id;

    if v_tutor_rate is null then
      raise exception 'Nie udało się ustalić stawki korepetytora.' using errcode = '55000';
    end if;

    v_period_start := date_trunc('month', v_lesson.lesson_date)::date;
    v_period_end := (v_period_start + interval '1 month - 1 day')::date;
    v_due_date := (v_period_start + interval '1 month 9 days')::date;

    insert into public.payout_periods (
      tutor_id, year, month, period_start, period_end, due_date
    ) values (
      v_lesson.tutor_id,
      extract(year from v_lesson.lesson_date)::integer,
      extract(month from v_lesson.lesson_date)::integer,
      v_period_start,
      v_period_end,
      v_due_date
    )
    on conflict (tutor_id, year, month)
    do update set
      period_start = excluded.period_start,
      period_end = excluded.period_end,
      due_date = excluded.due_date,
      updated_at = now()
    returning id, status into v_period_id, v_period_status;

    if v_period_status = 'PAID' then
      raise exception 'Miesiąc tej lekcji ma już zamkniętą wypłatę.' using errcode = '55000';
    end if;

    insert into public.payout_items (
      payout_period_id, lesson_id, rate_snapshot, amount, minutes
    ) values (
      v_period_id, p_lesson_id, v_tutor_rate, v_tutor_rate, 0
    )
    on conflict (lesson_id)
    do update set
      payout_period_id = excluded.payout_period_id,
      rate_snapshot = excluded.rate_snapshot,
      amount = excluded.amount,
      minutes = 0;

    perform public.edushot_recalculate_payout_period(v_period_id);
  else
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
  end if;

  select tutor.auth_user_id into v_tutor_auth_user_id
  from public.tutors tutor
  where tutor.id = v_lesson.tutor_id;

  if v_tutor_auth_user_id is not null then
    insert into public.notifications (user_id, type, title, message, lesson_id)
    values (
      v_tutor_auth_user_id,
      'lesson_cancelled_admin',
      case when v_is_late
        then 'Lekcja anulowana po terminie'
        else 'Lekcja została anulowana'
      end,
      'Administrator anulował lekcję ucznia ' || coalesce(v_lesson.student_name, 'EduSHOT') ||
      '. ' || case when v_is_late
        then 'Pełne wynagrodzenie zostało naliczone. '
        else 'Lekcja nie została naliczona do wynagrodzenia. '
      end || 'Powód: ' || v_reason,
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
      'tutor_id', v_lesson.tutor_id,
      'notice_minutes', v_notice_minutes,
      'cancellation_hours', v_cancellation_hours,
      'late_cancellation', v_is_late,
      'tutor_compensated', v_is_late
    )
  );

  return jsonb_build_object(
    'lesson_id', p_lesson_id,
    'status', v_target_status,
    'tutor_id', v_lesson.tutor_id,
    'regular_plan_id', v_lesson.regular_plan_id,
    'notice_minutes', v_notice_minutes,
    'cancellation_hours', v_cancellation_hours,
    'late_cancellation', v_is_late,
    'refund_eligible', not v_is_late,
    'tutor_compensated', v_is_late
  );
end;
$$;

revoke all on function public.edushot_admin_cancel_lesson(uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.edushot_admin_cancel_lesson(uuid, text, uuid, text)
  to service_role;

comment on function public.edushot_admin_cancel_lesson(uuid, text, uuid, text) is
  'Anuluje przyszłą lekcję na żądanie administratora i stosuje wspólną politykę anulowania oraz wynagrodzenia.';
