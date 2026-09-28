-- Use the central pricing matrix when a lesson finance snapshot is created.
-- Once created, the monetary snapshot is immutable; later status updates only
-- change revenue recognition. Paid periods are never rewritten.

create or replace function public.edushot_sync_lesson_finance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tutor_rate numeric(10,2);
  v_student_price numeric(10,2);
  v_recognized boolean;
  v_recognized_at timestamptz;
begin
  select lp.tutor_rate, lp.student_price
    into v_tutor_rate, v_student_price
  from public.lesson_pricing lp
  where lp.pricing_tier = new.pricing_tier
    and lp.duration_minutes = new.duration_minutes
    and lp.active = true
  limit 1;

  if v_tutor_rate is null or v_student_price is null then
    v_tutor_rate := public.edushot_tutor_rate_for_level(new.level);

    select bp.student_price
      into v_student_price
    from public.booking_policy bp
    order by bp.updated_at desc nulls last
    limit 1;
  end if;

  v_recognized := public.edushot_lesson_is_financially_final(
    new.status,
    new.attendance,
    new.cancellation_tutor_compensation
  );

  v_recognized_at := case
    when v_recognized then
      case
        when new.status = 'cancelled_late' then coalesce(new.cancelled_at, now())
        else now()
      end
    else null
  end;

  insert into public.lesson_finance (
    lesson_id,
    tutor_rate,
    student_price,
    revenue_recognized,
    revenue_recognized_at
  ) values (
    new.id,
    coalesce(v_tutor_rate, 0),
    coalesce(v_student_price, 0),
    v_recognized,
    v_recognized_at
  )
  on conflict (lesson_id)
  do update set
    revenue_recognized = excluded.revenue_recognized,
    revenue_recognized_at = case
      when excluded.revenue_recognized = true then coalesce(
        public.lesson_finance.revenue_recognized_at,
        excluded.revenue_recognized_at
      )
      else null
    end,
    updated_at = now();

  return new;
end;
$$;

-- Correct every still-unpaid lesson to the approved pricing matrix. This also
-- fixes the current open month while preserving any already-paid history.
update public.lesson_finance lf
set tutor_rate = lp.tutor_rate,
    student_price = lp.student_price,
    updated_at = now()
from public.lessons l
join public.lesson_pricing lp
  on lp.pricing_tier = l.pricing_tier
 and lp.duration_minutes = l.duration_minutes
 and lp.active = true
where lf.lesson_id = l.id
  and lf.payout_paid = false;

update public.payout_items pi
set rate_snapshot = lf.tutor_rate,
    amount = lf.tutor_rate
from public.lesson_finance lf,
     public.payout_periods pp
where pi.lesson_id = lf.lesson_id
  and pp.id = pi.payout_period_id
  and pp.status <> 'PAID';

do $$
declare
  v_period_id uuid;
begin
  for v_period_id in
    select id
    from public.payout_periods
    where status <> 'PAID'
  loop
    perform public.edushot_recalculate_payout_period(v_period_id);
  end loop;
end;
$$;

revoke all on function public.edushot_sync_lesson_finance()
  from public, anon, authenticated;
grant execute on function public.edushot_sync_lesson_finance()
  to service_role;

