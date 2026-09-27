-- Lock down helper search paths flagged by the Supabase security advisor.
alter function public.set_updated_at() set search_path = '';
alter function public.calculate_lesson_margin() set search_path = '';
alter function public.my_tutor_id() set search_path = '';
alter function public.edushot_lesson_is_financially_final(text, text, boolean) set search_path = '';
alter function public.edushot_lesson_is_payable(text, text) set search_path = '';

-- Remove default/public execution from every exposed application helper.
revoke all on function public.admin_assign_tutor_calcom(text, text, text, text) from public, anon, authenticated;
revoke all on function public.complete_tutor_onboarding() from public, anon, authenticated;
revoke all on function public.current_student_id() from public, anon, authenticated;
revoke all on function public.current_tutor_id() from public, anon, authenticated;
revoke all on function public.get_my_tutor_id() from public, anon, authenticated;
revoke all on function public.my_tutor_id() from public, anon, authenticated;
revoke all on function public.is_admin() from public, anon, authenticated;
revoke all on function public.mark_payout_paid(uuid, text) from public, anon, authenticated;
revoke all on function public.refresh_payout_period(uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.edushot_guard_tutor_lesson_update() from public, anon, authenticated;
revoke all on function public.edushot_guard_tutor_profile_update() from public, anon, authenticated;
revoke all on function public.edushot_recalculate_payout_period(uuid) from public, anon, authenticated;
revoke all on function public.edushot_sync_lesson_finance() from public, anon, authenticated;
revoke all on function public.edushot_sync_lesson_payout() from public, anon, authenticated;
revoke all on function public.edushot_sync_payout_from_lesson() from public, anon, authenticated;
revoke all on function public.guard_tutor_lesson_update() from public, anon, authenticated;
revoke all on function public.guard_tutor_profile_update() from public, anon, authenticated;
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.calculate_lesson_margin() from public, anon, authenticated;
revoke all on function public.edushot_lesson_is_financially_final(text, text, boolean) from public, anon, authenticated;
revoke all on function public.edushot_lesson_is_payable(text, text) from public, anon, authenticated;

-- Authenticated panels receive only the RPCs and RLS helpers they actually need.
grant execute on function public.admin_assign_tutor_calcom(text, text, text, text) to authenticated;
grant execute on function public.complete_tutor_onboarding() to authenticated;
grant execute on function public.current_student_id() to authenticated;
grant execute on function public.current_tutor_id() to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.mark_payout_paid(uuid, text) to authenticated;
grant execute on function public.refresh_payout_period(uuid, integer, integer) to authenticated;

-- Backend operations keep explicit access without relying on PUBLIC defaults.
grant execute on function public.admin_assign_tutor_calcom(text, text, text, text) to service_role;
grant execute on function public.complete_tutor_onboarding() to service_role;
grant execute on function public.current_student_id() to service_role;
grant execute on function public.current_tutor_id() to service_role;
grant execute on function public.get_my_tutor_id() to service_role;
grant execute on function public.my_tutor_id() to service_role;
grant execute on function public.is_admin() to service_role;
grant execute on function public.mark_payout_paid(uuid, text) to service_role;
grant execute on function public.refresh_payout_period(uuid, integer, integer) to service_role;
grant execute on function public.edushot_guard_tutor_lesson_update() to service_role;
grant execute on function public.edushot_guard_tutor_profile_update() to service_role;
grant execute on function public.edushot_recalculate_payout_period(uuid) to service_role;
grant execute on function public.edushot_sync_lesson_finance() to service_role;
grant execute on function public.edushot_sync_lesson_payout() to service_role;
grant execute on function public.edushot_sync_payout_from_lesson() to service_role;
grant execute on function public.guard_tutor_lesson_update() to service_role;
grant execute on function public.guard_tutor_profile_update() to service_role;
grant execute on function public.set_updated_at() to service_role;
grant execute on function public.calculate_lesson_margin() to service_role;
grant execute on function public.edushot_lesson_is_financially_final(text, text, boolean) to service_role;
grant execute on function public.edushot_lesson_is_payable(text, text) to service_role;

-- These are backend-only integration/legacy tables; the panels do not query them.
revoke all on table public.cal_integrations from public, anon, authenticated;
revoke all on table public.integration_events from public, anon, authenticated;
revoke all on table public.payouts from public, anon, authenticated;
revoke all on table public.system_settings from public, anon, authenticated;

grant select, insert, update, delete on table public.cal_integrations to service_role;
grant select, insert, update, delete on table public.integration_events to service_role;
grant select, insert, update, delete on table public.payouts to service_role;
grant select, insert, update, delete on table public.system_settings to service_role;
