-- EduSHOT: atomowe zatwierdzanie i cofanie wpłat rodziców.
-- Wpłata jest przypisywana do najstarszych otwartych okresów. Nadpłata
-- pozostaje nieprzypisana na koncie rodzica i może pokryć kolejny okres.

create or replace function public.edushot_refresh_all_guardian_billing(p_period_start date)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_guardian record;
  v_count integer := 0;
begin
  for v_guardian in
    select distinct guardian.id
    from public.guardians guardian
    join public.student_guardians link on link.guardian_id = guardian.id
    join public.students student on student.id = link.student_id
    where student.student_kind = 'regular'
  loop
    perform public.edushot_refresh_guardian_billing(v_guardian.id, p_period_start);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.edushot_admin_verify_guardian_payment(
  p_payment_id uuid,
  p_received_at timestamptz,
  p_admin_note text,
  p_actor_user_id uuid,
  p_actor_email text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_payment public.guardian_payments%rowtype;
  v_cycle public.guardian_billing_cycles%rowtype;
  v_remaining numeric(12,2);
  v_allocated numeric(12,2) := 0;
  v_amount numeric(12,2);
  v_cycle_id uuid;
begin
  select * into v_payment
  from public.guardian_payments where id = p_payment_id for update;
  if not found then raise exception 'Nie znaleziono wpłaty.' using errcode = 'P0002'; end if;
  if v_payment.status = 'succeeded' then
    return jsonb_build_object('payment_id', v_payment.id, 'status', v_payment.status, 'allocated', 0, 'credit', 0, 'idempotent', true);
  end if;
  if v_payment.status <> 'pending' then
    raise exception 'Można zatwierdzić tylko oczekującą wpłatę.' using errcode = '55000';
  end if;

  v_remaining := v_payment.amount;
  for v_cycle in
    select * from public.guardian_billing_cycles
    where guardian_id = v_payment.guardian_id
      and status not in ('paid', 'void') and balance_due > 0
    order by period_start asc for update
  loop
    exit when v_remaining <= 0;
    v_amount := least(v_remaining, v_cycle.balance_due);
    insert into public.guardian_payment_allocations(payment_id, cycle_id, amount)
    values (v_payment.id, v_cycle.id, v_amount)
    on conflict (payment_id, cycle_id) do nothing;
    if found then
      v_remaining := v_remaining - v_amount;
      v_allocated := v_allocated + v_amount;
      perform public.edushot_recalculate_guardian_cycle(v_cycle.id);
    end if;
  end loop;

  update public.guardian_payments set
    status = 'succeeded',
    received_at = coalesce(p_received_at, now()),
    verified_at = now(),
    verified_by = p_actor_user_id,
    note = nullif(btrim(p_admin_note), '')
  where id = v_payment.id;

  for v_cycle_id in
    select cycle_id from public.guardian_payment_allocations where payment_id = v_payment.id
  loop
    perform public.edushot_recalculate_guardian_cycle(v_cycle_id);
  end loop;

  update public.guardian_portal_requests set
    status = 'completed', resolved_by = p_actor_user_id, resolved_at = now(),
    resolution_note = coalesce(nullif(btrim(p_admin_note), ''), 'Wpłata potwierdzona przez administratora.')
  where guardian_id = v_payment.guardian_id
    and request_type = 'bank_transfer_declared'
    and requested_payload ->> 'payment_id' = v_payment.id::text
    and status = 'pending';

  insert into public.audit_logs(actor_user_id, actor_email, action, entity_type, entity_id, details)
  values (
    p_actor_user_id, p_actor_email, 'guardian_payment_verified', 'guardian_payment', v_payment.id::text,
    jsonb_build_object('guardian_id', v_payment.guardian_id, 'amount', v_payment.amount,
      'allocated', v_allocated, 'credit', v_remaining, 'method', v_payment.method)
  );
  return jsonb_build_object('payment_id', v_payment.id, 'status', 'succeeded',
    'allocated', v_allocated, 'credit', v_remaining, 'idempotent', false);
end;
$$;

create or replace function public.edushot_admin_reverse_guardian_payment(
  p_payment_id uuid,
  p_reason text,
  p_actor_user_id uuid,
  p_actor_email text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_payment public.guardian_payments%rowtype;
  v_cycle_id uuid;
  v_reason text := nullif(btrim(p_reason), '');
begin
  if v_reason is null then raise exception 'Podaj powód cofnięcia wpłaty.' using errcode = '22023'; end if;
  select * into v_payment from public.guardian_payments where id = p_payment_id for update;
  if not found then raise exception 'Nie znaleziono wpłaty.' using errcode = 'P0002'; end if;
  if v_payment.status = 'refunded' then
    return jsonb_build_object('payment_id', v_payment.id, 'status', 'refunded', 'idempotent', true);
  end if;
  if v_payment.status <> 'succeeded' then
    raise exception 'Można cofnąć tylko zatwierdzoną wpłatę.' using errcode = '55000';
  end if;

  for v_cycle_id in select cycle_id from public.guardian_payment_allocations where payment_id = v_payment.id
  loop
    delete from public.guardian_payment_allocations where payment_id = v_payment.id and cycle_id = v_cycle_id;
    perform public.edushot_recalculate_guardian_cycle(v_cycle_id);
  end loop;
  update public.guardian_payments set status = 'refunded', note = v_reason where id = v_payment.id;
  insert into public.audit_logs(actor_user_id, actor_email, action, entity_type, entity_id, details)
  values (p_actor_user_id, p_actor_email, 'guardian_payment_reversed', 'guardian_payment', v_payment.id::text,
    jsonb_build_object('guardian_id', v_payment.guardian_id, 'amount', v_payment.amount, 'reason', v_reason));
  return jsonb_build_object('payment_id', v_payment.id, 'status', 'refunded', 'idempotent', false);
end;
$$;

revoke all on function public.edushot_refresh_all_guardian_billing(date) from public, anon, authenticated;
revoke all on function public.edushot_admin_verify_guardian_payment(uuid,timestamptz,text,uuid,text) from public, anon, authenticated;
revoke all on function public.edushot_admin_reverse_guardian_payment(uuid,text,uuid,text) from public, anon, authenticated;
grant execute on function public.edushot_refresh_all_guardian_billing(date) to service_role;
grant execute on function public.edushot_admin_verify_guardian_payment(uuid,timestamptz,text,uuid,text) to service_role;
grant execute on function public.edushot_admin_reverse_guardian_payment(uuid,text,uuid,text) to service_role;
