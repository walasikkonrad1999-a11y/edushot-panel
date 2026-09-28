drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own
on public.profiles
for select
to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own
on public.profiles
for update
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists user_roles_select on public.user_roles;
create policy user_roles_select
on public.user_roles
for select
to authenticated
using (
  user_id = (select auth.uid())
  or (select public.is_admin())
);

drop policy if exists booking_policy_read on public.booking_policy;
create policy booking_policy_read
on public.booking_policy
for select
to authenticated
using (true);

drop policy if exists tutors_select on public.tutors;
create policy tutors_select
on public.tutors
for select
to authenticated
using (
  auth_user_id = (select auth.uid())
  or (select public.is_admin())
);

drop policy if exists tutors_update on public.tutors;
create policy tutors_update
on public.tutors
for update
to authenticated
using (
  auth_user_id = (select auth.uid())
  or (select public.is_admin())
)
with check (
  auth_user_id = (select auth.uid())
  or (select public.is_admin())
);

drop policy if exists students_select on public.students;
create policy students_select
on public.students
for select
to authenticated
using (
  auth_user_id = (select auth.uid())
  or (select public.is_admin())
);

drop policy if exists notifications_select on public.notifications;
create policy notifications_select
on public.notifications
for select
to authenticated
using (
  user_id = (select auth.uid())
  or (select public.is_admin())
);

drop policy if exists notifications_update on public.notifications;
create policy notifications_update
on public.notifications
for update
to authenticated
using (
  user_id = (select auth.uid())
  or (select public.is_admin())
)
with check (
  user_id = (select auth.uid())
  or (select public.is_admin())
);
