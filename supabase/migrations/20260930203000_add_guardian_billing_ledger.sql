-- EduSHOT: miesięczne rozliczenia rodziców stałych uczniów.
-- Operacyjna baza panelu pozostaje jedynym źródłem prawdy. Portal rodzica
-- otrzymuje dane wyłącznie przez podpisane, serwerowe API.

create table if not exists public.guardian_billing_profiles (
  guardian_id uuid primary key references public.guardians(id) on delete restrict,
  billing_day smallint not null default 1,
  payment_due_days smallint not null default 7,
  currency text not null default 'PLN',
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint guardian_billing_profiles_day_check check (billing_day between 1 and 28),
  constraint guardian_billing_profiles_due_check check (payment_due_days between 1 and 30),
  constraint guardian_billing_profiles_currency_check check (currency = 'PLN'),
  constraint guardian_billing_profiles_status_check check (status in ('active', 'paused', 'closed'))
);

create table if not exists public.guardian_billing_cycles (
  id uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references public.guardians(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  due_date date not null,
  currency text not null default 'PLN',
  status text not null default 'draft',
  subtotal numeric(12,2) not null default 0,
  adjustments_total numeric(12,2) not null default 0,
  paid_total numeric(12,2) not null default 0,
  balance_due numeric(12,2) not null default 0,
  opened_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (guardian_id, period_start),
  constraint guardian_billing_cycles_period_check check (period_end >= period_start),
  constraint guardian_billing_cycles_currency_check check (currency = 'PLN'),
  constraint guardian_billing_cycles_status_check check (
    status in ('draft', 'open', 'partially_paid', 'paid', 'overdue', 'void')
  )
);

create table if not exists public.guardian_billing_items (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.guardian_billing_cycles(id) on delete restrict,
  lesson_id uuid references public.lessons(id) on delete restrict,
  student_id uuid not null references public.students(id) on delete restrict,
  item_type text not null default 'lesson',
  description text not null,
  service_date date not null,
  amount numeric(12,2) not null,
  status text not null default 'active',
  source_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint guardian_billing_items_type_check check (item_type in ('lesson', 'adjustment', 'credit', 'refund')),
  constraint guardian_billing_items_status_check check (status in ('active', 'void')),
  constraint guardian_billing_items_description_check check (btrim(description) <> ''),
  constraint guardian_billing_items_lesson_check check (
    (item_type = 'lesson' and lesson_id is not null and amount >= 0)
    or (item_type <> 'lesson' and lesson_id is null)
  )
);

create unique index if not exists guardian_billing_items_lesson_uidx
  on public.guardian_billing_items (lesson_id) where lesson_id is not null;
create index if not exists guardian_billing_cycles_guardian_status_idx
  on public.guardian_billing_cycles (guardian_id, status, period_start desc);
create index if not exists guardian_billing_items_cycle_idx
  on public.guardian_billing_items (cycle_id, status, service_date);

create table if not exists public.guardian_payments (
  id uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references public.guardians(id) on delete restrict,
  method text not null,
  status text not null default 'pending',
  amount numeric(12,2) not null,
  currency text not null default 'PLN',
  provider text,
  provider_reference text,
  payer_reference text,
  declared_at timestamptz,
  received_at timestamptz,
  verified_at timestamptz,
  verified_by uuid references auth.users(id) on delete set null,
  note text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (idempotency_key),
  constraint guardian_payments_method_check check (method in ('stripe', 'bank_transfer', 'credit', 'refund')),
  constraint guardian_payments_status_check check (status in ('pending', 'succeeded', 'failed', 'cancelled', 'refunded')),
  constraint guardian_payments_amount_check check (amount > 0),
  constraint guardian_payments_currency_check check (currency = 'PLN')
);

create unique index if not exists guardian_payments_provider_reference_uidx
  on public.guardian_payments (provider, provider_reference)
  where provider is not null and provider_reference is not null;
create index if not exists guardian_payments_guardian_created_idx
  on public.guardian_payments (guardian_id, created_at desc);

create table if not exists public.guardian_payment_allocations (
  payment_id uuid not null references public.guardian_payments(id) on delete restrict,
  cycle_id uuid not null references public.guardian_billing_cycles(id) on delete restrict,
  amount numeric(12,2) not null,
  created_at timestamptz not null default now(),
  primary key (payment_id, cycle_id),
  constraint guardian_payment_allocations_amount_check check (amount > 0)
);

create table if not exists public.guardian_portal_requests (
  id uuid primary key default gen_random_uuid(),
  guardian_id uuid not null references public.guardians(id) on delete restrict,
  student_id uuid references public.students(id) on delete restrict,
  lesson_id uuid references public.lessons(id) on delete restrict,
  request_type text not null,
  status text not null default 'pending',
  requested_payload jsonb not null default '{}'::jsonb,
  resolution_note text,
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (guardian_id, idempotency_key),
  constraint guardian_portal_requests_type_check check (
    request_type in ('reschedule', 'bank_transfer_declared', 'billing_question')
  ),
  constraint guardian_portal_requests_status_check check (
    status in ('pending', 'approved', 'rejected', 'cancelled', 'completed')
  )
);

create index if not exists guardian_portal_requests_guardian_status_idx
  on public.guardian_portal_requests (guardian_id, status, created_at desc);

drop trigger if exists guardian_billing_profiles_updated_at on public.guardian_billing_profiles;
create trigger guardian_billing_profiles_updated_at before update on public.guardian_billing_profiles
for each row execute function public.set_updated_at();
drop trigger if exists guardian_billing_cycles_updated_at on public.guardian_billing_cycles;
create trigger guardian_billing_cycles_updated_at before update on public.guardian_billing_cycles
for each row execute function public.set_updated_at();
drop trigger if exists guardian_billing_items_updated_at on public.guardian_billing_items;
create trigger guardian_billing_items_updated_at before update on public.guardian_billing_items
for each row execute function public.set_updated_at();
drop trigger if exists guardian_payments_updated_at on public.guardian_payments;
create trigger guardian_payments_updated_at before update on public.guardian_payments
for each row execute function public.set_updated_at();
drop trigger if exists guardian_portal_requests_updated_at on public.guardian_portal_requests;
create trigger guardian_portal_requests_updated_at before update on public.guardian_portal_requests
for each row execute function public.set_updated_at();

alter table public.guardian_billing_profiles enable row level security;
alter table public.guardian_billing_cycles enable row level security;
alter table public.guardian_billing_items enable row level security;
alter table public.guardian_payments enable row level security;
alter table public.guardian_payment_allocations enable row level security;
alter table public.guardian_portal_requests enable row level security;

-- Portal korzysta z serwerowego API, a nie z bezpośredniego dostępu przeglądarki.
revoke all on table public.guardian_billing_profiles from public, anon, authenticated;
revoke all on table public.guardian_billing_cycles from public, anon, authenticated;
revoke all on table public.guardian_billing_items from public, anon, authenticated;
revoke all on table public.guardian_payments from public, anon, authenticated;
revoke all on table public.guardian_payment_allocations from public, anon, authenticated;
revoke all on table public.guardian_portal_requests from public, anon, authenticated;
grant select, insert, update, delete on table public.guardian_billing_profiles to service_role;
grant select, insert, update, delete on table public.guardian_billing_cycles to service_role;
grant select, insert, update, delete on table public.guardian_billing_items to service_role;
grant select, insert, update, delete on table public.guardian_payments to service_role;
grant select, insert, update, delete on table public.guardian_payment_allocations to service_role;
grant select, insert, update, delete on table public.guardian_portal_requests to service_role;

create or replace function public.edushot_recalculate_guardian_cycle(p_cycle_id uuid)
returns public.guardian_billing_cycles
language plpgsql security definer set search_path = ''
as $$
declare
  v_cycle public.guardian_billing_cycles%rowtype;
  v_subtotal numeric(12,2);
  v_adjustments numeric(12,2);
  v_paid numeric(12,2);
  v_balance numeric(12,2);
  v_status text;
begin
  select * into v_cycle from public.guardian_billing_cycles where id = p_cycle_id for update;
  if not found then raise exception 'Nie znaleziono okresu rozliczeniowego.' using errcode = 'P0002'; end if;

  select
    coalesce(sum(amount) filter (where item_type = 'lesson' and status = 'active'), 0),
    coalesce(sum(amount) filter (where item_type <> 'lesson' and status = 'active'), 0)
  into v_subtotal, v_adjustments
  from public.guardian_billing_items where cycle_id = p_cycle_id;

  select coalesce(sum(allocation.amount), 0) into v_paid
  from public.guardian_payment_allocations allocation
  join public.guardian_payments payment on payment.id = allocation.payment_id
  where allocation.cycle_id = p_cycle_id and payment.status = 'succeeded';

  v_balance := greatest(v_subtotal + v_adjustments - v_paid, 0);
  v_status := case
    when v_cycle.status = 'void' then 'void'
    when v_balance = 0 and v_subtotal + v_adjustments > 0 then 'paid'
    when v_paid > 0 then 'partially_paid'
    when v_cycle.opened_at is null then 'draft'
    when v_cycle.due_date < current_date then 'overdue'
    else 'open'
  end;

  update public.guardian_billing_cycles set
    subtotal = v_subtotal, adjustments_total = v_adjustments,
    paid_total = v_paid, balance_due = v_balance, status = v_status,
    paid_at = case when v_status = 'paid' then coalesce(paid_at, now()) else null end
  where id = p_cycle_id returning * into v_cycle;
  return v_cycle;
end;
$$;

create or replace function public.edushot_refresh_guardian_billing(
  p_guardian_id uuid,
  p_period_start date
)
returns public.guardian_billing_cycles
language plpgsql security definer set search_path = ''
as $$
declare
  v_period_start date := date_trunc('month', p_period_start)::date;
  v_period_end date := (date_trunc('month', p_period_start) + interval '1 month - 1 day')::date;
  v_due_days integer;
  v_cycle_id uuid;
  v_cycle public.guardian_billing_cycles%rowtype;
begin
  if not exists (select 1 from public.guardians where id = p_guardian_id) then
    raise exception 'Nie znaleziono rodzica.' using errcode = 'P0002';
  end if;

  insert into public.guardian_billing_profiles (guardian_id) values (p_guardian_id)
  on conflict (guardian_id) do nothing;
  select payment_due_days into v_due_days from public.guardian_billing_profiles where guardian_id = p_guardian_id;

  insert into public.guardian_billing_cycles (
    guardian_id, period_start, period_end, due_date, opened_at
  ) values (
    p_guardian_id, v_period_start, v_period_end, v_period_end + v_due_days,
    case when v_period_end < current_date then now() else null end
  ) on conflict (guardian_id, period_start) do update set
    period_end = excluded.period_end,
    due_date = excluded.due_date
  returning id into v_cycle_id;

  insert into public.guardian_billing_items (
    cycle_id, lesson_id, student_id, item_type, description,
    service_date, amount, source_snapshot
  )
  select
    v_cycle_id, lesson.id, lesson.student_id, 'lesson',
    coalesce(nullif(btrim(lesson.subject), ''), 'Lekcja EduSHOT') || ' · ' || lesson.duration_minutes || ' min',
    lesson.lesson_date, finance.student_price,
    jsonb_build_object(
      'lesson_status', lesson.status, 'pricing_tier', lesson.pricing_tier,
      'duration_minutes', lesson.duration_minutes, 'student_price', finance.student_price,
      'captured_at', now()
    )
  from public.lessons lesson
  join public.lesson_finance finance on finance.lesson_id = lesson.id
  join public.student_guardians link on link.student_id = lesson.student_id and link.guardian_id = p_guardian_id
  where lesson.lesson_date between v_period_start and v_period_end
    and finance.revenue_recognized = true
  on conflict (lesson_id) do nothing;

  -- Bezpłatne anulowanie nie może pozostawić pozycji na rachunku. Pozycję
  -- zachowujemy jako void, aby historia korekt była audytowalna.
  update public.guardian_billing_items item set status = 'void'
  from public.lessons lesson, public.lesson_finance finance
  where item.cycle_id = v_cycle_id and item.lesson_id = lesson.id
    and finance.lesson_id = lesson.id and finance.revenue_recognized = false
    and item.status <> 'void';

  select * into v_cycle from public.edushot_recalculate_guardian_cycle(v_cycle_id);
  return v_cycle;
end;
$$;

create or replace function public.edushot_declare_bank_transfer(
  p_guardian_id uuid,
  p_amount numeric,
  p_payer_reference text,
  p_idempotency_key text
)
returns public.guardian_payments
language plpgsql security definer set search_path = ''
as $$
declare
  v_payment public.guardian_payments%rowtype;
  v_reference text := nullif(btrim(p_payer_reference), '');
begin
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    raise exception 'Podaj prawidłową kwotę przelewu.' using errcode = '22023';
  end if;
  if v_reference is null or char_length(v_reference) > 160 then
    raise exception 'Podaj tytuł lub identyfikator przelewu.' using errcode = '22023';
  end if;
  if nullif(btrim(p_idempotency_key), '') is null then
    raise exception 'Brak klucza operacji.' using errcode = '22023';
  end if;

  select * into v_payment from public.guardian_payments
  where idempotency_key = p_idempotency_key;
  if found then
    if v_payment.guardian_id <> p_guardian_id or v_payment.method <> 'bank_transfer' then
      raise exception 'Konflikt klucza operacji.' using errcode = '23505';
    end if;
    return v_payment;
  end if;

  insert into public.guardian_payments (
    guardian_id, method, status, amount, payer_reference,
    declared_at, idempotency_key
  ) values (
    p_guardian_id, 'bank_transfer', 'pending', p_amount, v_reference,
    now(), p_idempotency_key
  ) returning * into v_payment;

  insert into public.guardian_portal_requests (
    guardian_id, request_type, requested_payload, idempotency_key
  ) values (
    p_guardian_id, 'bank_transfer_declared',
    jsonb_build_object('payment_id', v_payment.id, 'amount', p_amount, 'payer_reference', v_reference),
    p_idempotency_key
  );
  return v_payment;
end;
$$;

revoke all on function public.edushot_recalculate_guardian_cycle(uuid) from public, anon, authenticated;
revoke all on function public.edushot_refresh_guardian_billing(uuid, date) from public, anon, authenticated;
revoke all on function public.edushot_declare_bank_transfer(uuid, numeric, text, text) from public, anon, authenticated;
grant execute on function public.edushot_recalculate_guardian_cycle(uuid) to service_role;
grant execute on function public.edushot_refresh_guardian_billing(uuid, date) to service_role;
grant execute on function public.edushot_declare_bank_transfer(uuid, numeric, text, text) to service_role;

comment on table public.guardian_billing_cycles is
  'Miesięczne, audytowalne rozliczenia rodziców. Kwoty wynikają z finansowego snapshotu lekcji.';
comment on table public.guardian_payments is
  'Niezależny rejestr wpłat online, przelewów bankowych, korekt i zwrotów; nie zmienia wynagrodzenia tutora.';

