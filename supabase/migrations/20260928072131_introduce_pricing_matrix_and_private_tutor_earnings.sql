-- Central pricing matrix for new bookings. Existing lesson_finance rows are
-- intentionally left unchanged so historical settlements stay immutable.
create table if not exists public.lesson_pricing (
  pricing_tier text not null,
  duration_minutes integer not null,
  student_price numeric(10, 2) not null,
  tutor_rate numeric(10, 2) not null,
  currency text not null default 'PLN',
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (pricing_tier, duration_minutes),
  constraint lesson_pricing_tier_check check (
    pricing_tier in ('primary_school', 'secondary_basic', 'secondary_extended')
  ),
  constraint lesson_pricing_duration_check check (duration_minutes in (30, 60, 90)),
  constraint lesson_pricing_amounts_check check (
    student_price >= 0 and tutor_rate >= 0 and student_price >= tutor_rate
  )
);

alter table public.lesson_pricing enable row level security;

insert into public.lesson_pricing (
  pricing_tier,
  duration_minutes,
  student_price,
  tutor_rate,
  currency,
  active
)
values
  ('primary_school', 30, 40.00, 17.50, 'PLN', true),
  ('primary_school', 60, 60.00, 35.00, 'PLN', true),
  ('primary_school', 90, 90.00, 52.50, 'PLN', true),
  ('secondary_basic', 30, 45.00, 20.00, 'PLN', true),
  ('secondary_basic', 60, 70.00, 40.00, 'PLN', true),
  ('secondary_basic', 90, 105.00, 60.00, 'PLN', true),
  ('secondary_extended', 30, 50.00, 22.50, 'PLN', true),
  ('secondary_extended', 60, 80.00, 45.00, 'PLN', true),
  ('secondary_extended', 90, 120.00, 67.50, 'PLN', true)
on conflict (pricing_tier, duration_minutes) do update
set student_price = excluded.student_price,
    tutor_rate = excluded.tutor_rate,
    currency = excluded.currency,
    active = excluded.active,
    updated_at = now();

alter table public.lessons
  add column if not exists pricing_tier text;

alter table public.lessons
  drop constraint if exists lessons_pricing_tier_check;

alter table public.lessons
  add constraint lessons_pricing_tier_check check (
    pricing_tier is null or
    pricing_tier in ('primary_school', 'secondary_basic', 'secondary_extended')
  );

update public.lessons
set pricing_tier = case
  when lower(coalesce(subject, '')) like '%szkoła podstawowa%'
    or lower(coalesce(subject, '')) like '%szkola podstawowa%'
    then 'primary_school'
  when lower(coalesce(level, '')) like '%rozszerz%'
    or lower(coalesce(subject, '')) like '%rozszerz%'
    then 'secondary_extended'
  else 'secondary_basic'
end
where pricing_tier is null;

drop policy if exists lesson_pricing_admin_all on public.lesson_pricing;
create policy lesson_pricing_admin_all
on public.lesson_pricing
for all
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

revoke all on table public.lesson_pricing from public, anon, authenticated;
grant select, insert, update, delete on table public.lesson_pricing to service_role;
grant select, insert, update, delete on table public.lesson_pricing to authenticated;

-- Tutors must never receive the parent price or EduSHOT margin. Direct reads
-- from lesson_finance are therefore restricted to administrators.
drop policy if exists lesson_finance_select on public.lesson_finance;
create policy lesson_finance_select
on public.lesson_finance
for select
to authenticated
using ((select public.is_admin()));

create or replace function public.get_my_lesson_earnings()
returns table (
  lesson_id uuid,
  tutor_rate numeric,
  payout_paid boolean,
  payout_date timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  select
    lf.lesson_id,
    lf.tutor_rate,
    lf.payout_paid,
    lf.payout_date
  from public.lesson_finance lf
  join public.lessons l on l.id = lf.lesson_id
  join public.tutors t on t.id = l.tutor_id
  where t.auth_user_id = (select auth.uid());
$$;

create or replace function public.get_my_booking_rules()
returns table (
  cancellation_hours integer,
  reschedule_hours integer,
  currency text
)
language sql
security definer
set search_path = ''
stable
as $$
  select bp.cancellation_hours, bp.reschedule_hours, bp.currency
  from public.booking_policy bp
  where bp.id = 1
    and exists (
      select 1
      from public.tutors t
      where t.auth_user_id = (select auth.uid())
        and t.status = 'active'
    );
$$;

create or replace function public.get_my_tutor_rates()
returns table (
  pricing_tier text,
  duration_minutes integer,
  tutor_rate numeric,
  currency text
)
language sql
security definer
set search_path = ''
stable
as $$
  select lp.pricing_tier, lp.duration_minutes, lp.tutor_rate, lp.currency
  from public.lesson_pricing lp
  where lp.active
    and exists (
      select 1
      from public.tutors t
      where t.auth_user_id = (select auth.uid())
        and t.status = 'active'
    )
  order by lp.pricing_tier, lp.duration_minutes;
$$;

revoke all on function public.get_my_lesson_earnings() from public, anon;
revoke all on function public.get_my_booking_rules() from public, anon;
revoke all on function public.get_my_tutor_rates() from public, anon;
grant execute on function public.get_my_lesson_earnings() to authenticated, service_role;
grant execute on function public.get_my_booking_rules() to authenticated, service_role;
grant execute on function public.get_my_tutor_rates() to authenticated, service_role;

