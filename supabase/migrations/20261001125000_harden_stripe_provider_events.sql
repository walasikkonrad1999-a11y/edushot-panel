-- Jawna polityka deny uzupełnia odebrane granty. Zdarzenia dostawcy płatności
-- są dostępne wyłącznie dla service_role używanej przez podpisany webhook.
create policy guardian_payment_provider_events_deny_client
on public.guardian_payment_provider_events for all to authenticated
using (false) with check (false);

