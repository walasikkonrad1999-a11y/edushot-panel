-- Jawnie blokujemy dostęp klienta. Service role omija RLS i pozostaje jedyną
-- drogą używaną przez podpisane API portalu rodzica.

create policy guardian_billing_profiles_deny_client
on public.guardian_billing_profiles for all to authenticated
using (false) with check (false);
create policy guardian_billing_cycles_deny_client
on public.guardian_billing_cycles for all to authenticated
using (false) with check (false);
create policy guardian_billing_items_deny_client
on public.guardian_billing_items for all to authenticated
using (false) with check (false);
create policy guardian_payments_deny_client
on public.guardian_payments for all to authenticated
using (false) with check (false);
create policy guardian_payment_allocations_deny_client
on public.guardian_payment_allocations for all to authenticated
using (false) with check (false);
create policy guardian_portal_requests_deny_client
on public.guardian_portal_requests for all to authenticated
using (false) with check (false);

create index if not exists guardian_billing_items_student_idx
  on public.guardian_billing_items (student_id);
create index if not exists guardian_payment_allocations_cycle_idx
  on public.guardian_payment_allocations (cycle_id);
create index if not exists guardian_payments_verified_by_idx
  on public.guardian_payments (verified_by) where verified_by is not null;
create index if not exists guardian_portal_requests_student_idx
  on public.guardian_portal_requests (student_id) where student_id is not null;
create index if not exists guardian_portal_requests_lesson_idx
  on public.guardian_portal_requests (lesson_id) where lesson_id is not null;
create index if not exists guardian_portal_requests_resolved_by_idx
  on public.guardian_portal_requests (resolved_by) where resolved_by is not null;

