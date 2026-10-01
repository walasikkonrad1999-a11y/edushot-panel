-- EduSHOT: bezpieczne i idempotentne rozliczanie Stripe Checkout.
-- Checkout powstaje po stronie Workera, ale dopiero podpisany webhook Stripe
-- może oznaczyć wpłatę jako otrzymaną i przypisać ją do okresów rozliczeniowych.

create table if not exists public.guardian_payment_provider_events (
  provider text not null,
  event_id text not null,
  event_type text not null,
  payment_id uuid references public.guardian_payments(id) on delete restrict,
  processed_at timestamptz not null default now(),
  primary key (provider, event_id),
  constraint guardian_payment_provider_events_provider_check check (provider in ('stripe')),
  constraint guardian_payment_provider_events_event_id_check check (btrim(event_id) <> ''),
  constraint guardian_payment_provider_events_event_type_check check (btrim(event_type) <> '')
);

alter table public.guardian_payment_provider_events enable row level security;
revoke all on table public.guardian_payment_provider_events from public, anon, authenticated;
grant select, insert on table public.guardian_payment_provider_events to service_role;

create or replace function public.edushot_create_stripe_payment(
  p_guardian_id uuid,
  p_amount numeric,
  p_idempotency_key text
)
returns public.guardian_payments
language plpgsql security definer set search_path = ''
as $$
declare
  v_payment public.guardian_payments%rowtype;
  v_key text := nullif(btrim(p_idempotency_key), '');
  v_outstanding numeric(12,2);
begin
  if v_key is null or char_length(v_key) > 120 then
    raise exception 'Brak prawidłowego klucza operacji.' using errcode = '22023';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 100000 then
    raise exception 'Kwota płatności musi wynosić od 1 do 100000 zł.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.guardians where id = p_guardian_id) then
    raise exception 'Nie znaleziono rodzica.' using errcode = 'P0002';
  end if;

  select * into v_payment from public.guardian_payments where idempotency_key = v_key;
  if found then
    if v_payment.guardian_id <> p_guardian_id or v_payment.method <> 'stripe' or v_payment.amount <> round(p_amount, 2) then
      raise exception 'Konflikt klucza operacji.' using errcode = '23505';
    end if;
    return v_payment;
  end if;

  select coalesce(sum(balance_due), 0) into v_outstanding
  from public.guardian_billing_cycles
  where guardian_id = p_guardian_id and status not in ('paid', 'void') and balance_due > 0;
  if v_outstanding <= 0 then
    raise exception 'Na koncie nie ma obecnie kwoty do opłacenia.' using errcode = '22023';
  end if;
  if round(p_amount, 2) > v_outstanding then
    raise exception 'Kwota płatności przekracza aktualną należność.' using errcode = '22023';
  end if;

  insert into public.guardian_payments (
    guardian_id, method, status, amount, currency, provider, idempotency_key
  ) values (
    p_guardian_id, 'stripe', 'pending', round(p_amount, 2), 'PLN', 'stripe', v_key
  ) returning * into v_payment;
  return v_payment;
end;
$$;

create or replace function public.edushot_settle_stripe_payment(
  p_payment_id uuid,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_amount_minor bigint,
  p_currency text,
  p_received_at timestamptz,
  p_event_id text,
  p_event_type text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_payment public.guardian_payments%rowtype;
  v_result jsonb;
begin
  select * into v_payment from public.guardian_payments where id = p_payment_id for update;
  if not found then raise exception 'Nie znaleziono wpłaty Stripe.' using errcode = 'P0002'; end if;
  if v_payment.method <> 'stripe' or v_payment.provider <> 'stripe' then
    raise exception 'Wpłata nie należy do Stripe.' using errcode = '22023';
  end if;
  if nullif(btrim(p_checkout_session_id), '') is null
     or v_payment.provider_reference is distinct from p_checkout_session_id then
    raise exception 'Niezgodna sesja Stripe.' using errcode = '22023';
  end if;
  if upper(coalesce(p_currency, '')) <> 'PLN'
     or p_amount_minor <> round(v_payment.amount * 100)::bigint then
    raise exception 'Niezgodna kwota lub waluta płatności Stripe.' using errcode = '22023';
  end if;

  insert into public.guardian_payment_provider_events(provider, event_id, event_type, payment_id)
  values ('stripe', p_event_id, p_event_type, v_payment.id)
  on conflict (provider, event_id) do nothing;
  if not found then
    return jsonb_build_object('payment_id', v_payment.id, 'status', v_payment.status, 'idempotent', true);
  end if;

  select public.edushot_admin_verify_guardian_payment(
    v_payment.id, coalesce(p_received_at, now()),
    'Stripe Checkout' || case when nullif(btrim(p_payment_intent_id), '') is not null
      then ' · ' || p_payment_intent_id else '' end,
    null, 'stripe-webhook'
  ) into v_result;
  return v_result || jsonb_build_object('event_id', p_event_id);
end;
$$;

create or replace function public.edushot_fail_stripe_payment(
  p_payment_id uuid,
  p_checkout_session_id text,
  p_event_id text,
  p_event_type text
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_payment public.guardian_payments%rowtype;
begin
  select * into v_payment from public.guardian_payments where id = p_payment_id for update;
  if not found then raise exception 'Nie znaleziono wpłaty Stripe.' using errcode = 'P0002'; end if;
  if v_payment.method <> 'stripe' or v_payment.provider_reference is distinct from p_checkout_session_id then
    raise exception 'Niezgodna sesja Stripe.' using errcode = '22023';
  end if;
  insert into public.guardian_payment_provider_events(provider, event_id, event_type, payment_id)
  values ('stripe', p_event_id, p_event_type, v_payment.id)
  on conflict (provider, event_id) do nothing;
  if not found then
    return jsonb_build_object('payment_id', v_payment.id, 'status', v_payment.status, 'idempotent', true);
  end if;
  if v_payment.status = 'pending' then
    update public.guardian_payments set status = 'failed', note = 'Sesja Stripe wygasła lub płatność nie powiodła się.'
    where id = v_payment.id;
  end if;
  return jsonb_build_object('payment_id', v_payment.id,
    'status', case when v_payment.status = 'pending' then 'failed' else v_payment.status end,
    'idempotent', false);
end;
$$;

revoke all on function public.edushot_create_stripe_payment(uuid,numeric,text) from public, anon, authenticated;
revoke all on function public.edushot_settle_stripe_payment(uuid,text,text,bigint,text,timestamptz,text,text) from public, anon, authenticated;
revoke all on function public.edushot_fail_stripe_payment(uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.edushot_create_stripe_payment(uuid,numeric,text) to service_role;
grant execute on function public.edushot_settle_stripe_payment(uuid,text,text,bigint,text,timestamptz,text,text) to service_role;
grant execute on function public.edushot_fail_stripe_payment(uuid,text,text,text) to service_role;

