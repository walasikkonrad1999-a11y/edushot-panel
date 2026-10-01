-- EduSHOT: bezpieczny fundament pod moduł stałych uczniów.
-- Ta migracja nie zmienia żadnej istniejącej lekcji ani kwoty rozliczenia.

-- Historia lekcji i finansów nie może zniknąć po omyłkowym twardym usunięciu
-- korepetytora. Aplikacja usuwa dostęp przez archiwizację rekordu tutors.
alter table public.lessons
  drop constraint if exists lessons_tutor_id_fkey;

alter table public.lessons
  add constraint lessons_tutor_id_fkey
  foreign key (tutor_id)
  references public.tutors(id)
  on delete restrict;

-- API wyniku lekcji obsługuje no_show, więc ograniczenie bazy musi przyjmować
-- dokładnie ten sam zestaw wartości.
alter table public.lessons
  drop constraint if exists lessons_attendance_check;

alter table public.lessons
  add constraint lessons_attendance_check
  check (
    attendance is null
    or attendance in ('held', 'late', 'no_show', 'cancelled')
  );

-- Pole rate jest polem zgodności wstecznej. Finansowe źródło prawdy pozostaje
-- w lesson_finance, ale nowe lekcje rozszerzone nie mogą być odrzucane przez
-- historyczne ograniczenie 35/40 zł.
alter table public.lessons
  drop constraint if exists lessons_rate_check;

alter table public.lessons
  add constraint lessons_rate_check
  check (rate in (35, 40, 45));

-- Stara funkcja purge usuwała lekcje i ich rozliczenia. Nie jest używana przez
-- aktualny panel (panel archiwizuje korepetytora), dlatego odbieramy dostęp do
-- niej rolom aplikacyjnym. Zachowujemy ją wyłącznie dla właściciela bazy, aby
-- ewentualna prawnie wymagana operacja mogła zostać przeprowadzona świadomie.
revoke all on function public.purge_tutor_data(uuid)
  from public, anon, authenticated, service_role;

-- Jawnie ograniczamy istniejące polityki do zalogowanych użytkowników.
-- Warunki własności i uprawnień administratora pozostają bez zmian.
alter policy audit_logs_admin_select on public.audit_logs
  to authenticated;

alter policy booking_policy_admin_update on public.booking_policy
  to authenticated;

alter policy lesson_finance_admin_all on public.lesson_finance
  to authenticated;

alter policy lessons_admin_delete on public.lessons
  to authenticated;

alter policy lessons_admin_insert on public.lessons
  to authenticated;

alter policy lessons_select on public.lessons
  to authenticated;

alter policy notifications_admin_all on public.notifications
  to authenticated;

alter policy payout_items_admin_all on public.payout_items
  to authenticated;

alter policy payout_items_select on public.payout_items
  to authenticated;

alter policy payout_periods_admin_all on public.payout_periods
  to authenticated;

alter policy payout_periods_select on public.payout_periods
  to authenticated;

alter policy students_admin_all on public.students
  to authenticated;

alter policy tutor_availability_own on public.tutor_availability
  to authenticated;

alter policy reviews_admin_all on public.tutor_reviews
  to authenticated;

alter policy reviews_select on public.tutor_reviews
  to authenticated;

alter policy tutor_time_off_own on public.tutor_time_off
  to authenticated;

alter policy tutors_admin_delete on public.tutors
  to authenticated;

alter policy tutors_admin_insert on public.tutors
  to authenticated;

alter policy user_roles_admin_all on public.user_roles
  to authenticated;

-- Tabele integracyjne są backend-only. Brak polityk jest zamierzony, a role
-- przeglądarkowe nie mają do nich grantów w Data API.
revoke all on table public.cal_integrations from anon, authenticated;
revoke all on table public.integration_events from anon, authenticated;
revoke all on table public.payouts from anon, authenticated;
revoke all on table public.system_settings from anon, authenticated;

grant select, insert, update, delete on table public.cal_integrations
  to service_role;
grant select, insert, update, delete on table public.integration_events
  to service_role;
grant select, insert, update, delete on table public.payouts
  to service_role;
grant select, insert, update, delete on table public.system_settings
  to service_role;
