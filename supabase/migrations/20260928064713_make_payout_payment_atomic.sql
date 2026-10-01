alter table public.audit_logs
  add column if not exists actor_user_id uuid,
  add column if not exists entity_type text,
  add column if not exists entity_id text,
  add column if not exists details jsonb not null default '{}'::jsonb;

create or replace function public.mark_payout_paid(
  p_period_id uuid,
  p_reference text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := (select auth.uid());
  v_actor_email text := (select auth.jwt() ->> 'email');
  v_paid_at timestamptz;
  v_payment_time timestamptz := now();
begin
  if v_actor_id is null or not coalesce(public.is_admin(), false) then
    raise exception 'Forbidden' using errcode = '42501';
  end if;

  select paid_at
    into v_paid_at
  from public.payout_periods
  where id = p_period_id
  for update;

  if not found then
    raise exception 'Payout period not found' using errcode = 'P0002';
  end if;

  if v_paid_at is not null then
    return;
  end if;

  update public.payout_periods
  set
    status = 'PAID',
    paid_at = v_payment_time,
    payment_reference = nullif(btrim(p_reference), ''),
    updated_at = v_payment_time
  where id = p_period_id;

  update public.lesson_finance
  set
    payout_paid = true,
    payout_date = v_payment_time,
    updated_at = v_payment_time
  where lesson_id in (
    select lesson_id
    from public.payout_items
    where payout_period_id = p_period_id
  );

  update public.lessons
  set payout_paid = true
  where id in (
    select lesson_id
    from public.payout_items
    where payout_period_id = p_period_id
  );

  insert into public.audit_logs (
    actor_user_id,
    actor_email,
    action,
    entity_type,
    entity_id,
    details
  ) values (
    v_actor_id,
    v_actor_email,
    'payout_paid',
    'payout_period',
    p_period_id::text,
    jsonb_build_object(
      'payment_reference',
      nullif(btrim(p_reference), ''),
      'paid_at',
      v_payment_time
    )
  );
end;
$$;

revoke all on function public.mark_payout_paid(uuid, text)
  from public, anon, authenticated;
grant execute on function public.mark_payout_paid(uuid, text)
  to authenticated, service_role;
