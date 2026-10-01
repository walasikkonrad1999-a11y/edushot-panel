-- EduSHOT: spójność operacyjna paneli, Cal.com i rozliczeń.
-- Migracja nie usuwa danych i zachowuje istniejące identyfikatory.

alter table public.booking_policy
  add column if not exists student_price numeric(10, 2) not null default 70.00;

alter table public.audit_logs
  add column if not exists actor_user_id uuid,
  add column if not exists entity_type text,
  add column if not exists entity_id text,
  add column if not exists details jsonb not null default '{}'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'booking_policy_nonnegative_amounts'
      and conrelid = 'public.booking_policy'::regclass
  ) then
    alter table public.booking_policy
      add constraint booking_policy_nonnegative_amounts
      check (
        basic_tutor_rate >= 0
        and extended_tutor_rate >= 0
        and student_price >= 0
      );
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'tutor_time_off_valid_range'
      and conrelid = 'public.tutor_time_off'::regclass
  ) then
    alter table public.tutor_time_off
      add constraint tutor_time_off_valid_range
      check (date_to >= date_from);
  end if;
end
$$;

create unique index if not exists tutor_time_off_tutor_range_uidx
  on public.tutor_time_off (tutor_id, date_from, date_to);

-- Dwa triggery wypłat wykonywały tę samą pracę. Zachowujemy nowszą,
-- pełniejszą implementację edushot_sync_payout_from_lesson().
drop trigger if exists edushot_lesson_payout_sync on public.lessons;
drop function if exists public.edushot_sync_lesson_payout();

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
    paid_at = now(),
    payment_reference = nullif(btrim(p_reference), ''),
    updated_at = now()
  where id = p_period_id;

  update public.lesson_finance
  set
    payout_paid = true,
    payout_date = now(),
    updated_at = now()
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
    jsonb_build_object('payment_reference', nullif(btrim(p_reference), ''))
  );
end;
$$;

revoke all on function public.mark_payout_paid(uuid, text) from public, anon;
grant execute on function public.mark_payout_paid(uuid, text) to authenticated;

revoke all on function public.refresh_payout_period(uuid, integer, integer)
  from public, anon;
grant execute on function public.refresh_payout_period(uuid, integer, integer)
  to authenticated;

-- Polityki są jawnie ograniczone do zalogowanych użytkowników.
drop policy if exists tutor_time_off_own on public.tutor_time_off;
create policy tutor_time_off_own
on public.tutor_time_off
for all
to authenticated
using (
  tutor_id = (select public.current_tutor_id())
  or (select public.is_admin())
)
with check (
  tutor_id = (select public.current_tutor_id())
  or (select public.is_admin())
);

drop policy if exists audit_logs_admin_select on public.audit_logs;
create policy audit_logs_admin_select
on public.audit_logs
for select
to authenticated
using ((select public.is_admin()));

drop policy if exists booking_policy_read on public.booking_policy;
create policy booking_policy_read
on public.booking_policy
for select
to authenticated
using (true);

drop policy if exists booking_policy_admin_update on public.booking_policy;
create policy booking_policy_admin_update
on public.booking_policy
for update
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

-- Jawne uprawnienia Data API wymagane przez aktualne zasady Supabase.
revoke all on table public.tutor_time_off from anon;
grant select, insert, update, delete on table public.tutor_time_off to authenticated;
grant select, insert, update, delete on table public.tutor_time_off to service_role;

revoke all on table public.audit_logs from anon;
grant select on table public.audit_logs to authenticated;
grant select, insert on table public.audit_logs to service_role;

revoke all on table public.booking_policy from anon;
grant select, update on table public.booking_policy to authenticated;
grant select, update on table public.booking_policy to service_role;

