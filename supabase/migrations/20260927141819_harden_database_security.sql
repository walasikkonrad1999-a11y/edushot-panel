-- EduSHOT: ograniczenie powierzchni Data API i poprawa bezpieczeństwa funkcji.
-- Funkcje triggerów nadal wykonują się automatycznie; odbieramy jedynie możliwość
-- wywołania ich bezpośrednio przez endpoint RPC.

alter function public.set_updated_at() set search_path = '';
alter function public.calculate_lesson_margin() set search_path = '';
alter function public.my_tutor_id() set search_path = '';
alter function public.edushot_lesson_is_financially_final(text, text, boolean)
  set search_path = '';
alter function public.edushot_lesson_is_payable(text, text)
  set search_path = '';

revoke all on function public.admin_assign_tutor_calcom(text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.complete_tutor_onboarding()
  from public, anon, authenticated;
revoke all on function public.current_student_id()
  from public, anon, authenticated;
revoke all on function public.current_tutor_id()
  from public, anon, authenticated;
revoke all on function public.get_my_tutor_id()
  from public, anon, authenticated;
revoke all on function public.my_tutor_id()
  from public, anon, authenticated;
revoke all on function public.is_admin()
  from public, anon, authenticated;
revoke all on function public.mark_payout_paid(uuid, text)
  from public, anon, authenticated;
revoke all on function public.refresh_payout_period(uuid, integer, integer)
  from public, anon, authenticated;

revoke all on function public.edushot_guard_tutor_lesson_update()
  from public, anon, authenticated;
revoke all on function public.edushot_guard_tutor_profile_update()
  from public, anon, authenticated;
revoke all on function public.edushot_recalculate_payout_period(uuid)
  from public, anon, authenticated;
revoke all on function public.edushot_sync_lesson_finance()
  from public, anon, authenticated;
revoke all on function public.edushot_sync_payout_from_lesson()
  from public, anon, authenticated;
revoke all on function public.guard_tutor_lesson_update()
  from public, anon, authenticated;
revoke all on function public.guard_tutor_profile_update()
  from public, anon, authenticated;
revoke all on function public.set_updated_at()
  from public, anon, authenticated;
revoke all on function public.calculate_lesson_margin()
  from public, anon, authenticated;
revoke all on function public.edushot_lesson_is_financially_final(text, text, boolean)
  from public, anon, authenticated;
revoke all on function public.edushot_lesson_is_payable(text, text)
  from public, anon, authenticated;

-- Zalogowane panele dostają tylko RPC, których rzeczywiście używają lub które
-- są potrzebne do sprawdzenia własnej tożsamości w politykach RLS.
grant execute on function public.admin_assign_tutor_calcom(text, text, text, text)
  to authenticated;
grant execute on function public.complete_tutor_onboarding()
  to authenticated;
grant execute on function public.current_student_id()
  to authenticated;
grant execute on function public.current_tutor_id()
  to authenticated;
grant execute on function public.get_my_tutor_id()
  to authenticated;
grant execute on function public.my_tutor_id()
  to authenticated;
grant execute on function public.is_admin()
  to authenticated;
grant execute on function public.mark_payout_paid(uuid, text)
  to authenticated;
grant execute on function public.refresh_payout_period(uuid, integer, integer)
  to authenticated;

-- Backend z kluczem sekretowym zachowuje dostęp do funkcji operacyjnych.
grant execute on function public.admin_assign_tutor_calcom(text, text, text, text)
  to service_role;
grant execute on function public.complete_tutor_onboarding()
  to service_role;
grant execute on function public.current_student_id()
  to service_role;
grant execute on function public.current_tutor_id()
  to service_role;
grant execute on function public.get_my_tutor_id()
  to service_role;
grant execute on function public.my_tutor_id()
  to service_role;
grant execute on function public.is_admin()
  to service_role;
grant execute on function public.mark_payout_paid(uuid, text)
  to service_role;
grant execute on function public.refresh_payout_period(uuid, integer, integer)
  to service_role;
grant execute on function public.edushot_recalculate_payout_period(uuid)
  to service_role;

-- Tabele integracyjne są backend-only. RLS bez polityk celowo blokuje klientów,
-- a jawne revoke usuwa ich niepotrzebne granty Data API.
revoke all on table public.cal_integrations from anon, authenticated;
revoke all on table public.integration_events from anon, authenticated;
revoke all on table public.payouts from anon, authenticated;
revoke all on table public.system_settings from anon, authenticated;

grant select, insert, update, delete on table public.cal_integrations to service_role;
grant select, insert, update, delete on table public.integration_events to service_role;
grant select, insert, update, delete on table public.payouts to service_role;
grant select, insert, update, delete on table public.system_settings to service_role;

-- Indeksy dla kluczy obcych wskazanych przez doradcę wydajności Supabase.
create index if not exists notifications_lesson_id_idx
  on public.notifications (lesson_id);

create index if not exists tutor_reviews_student_id_idx
  on public.tutor_reviews (student_id);
