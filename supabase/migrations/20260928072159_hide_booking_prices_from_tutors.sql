-- Booking policy still contains legacy price columns for backwards
-- compatibility. Only administrators may read the row directly; tutors use
-- get_my_booking_rules(), which exposes no client prices.
drop policy if exists booking_policy_read on public.booking_policy;
drop policy if exists booking_policy_admin_select on public.booking_policy;

create policy booking_policy_admin_select
on public.booking_policy
for select
to authenticated
using ((select public.is_admin()));

