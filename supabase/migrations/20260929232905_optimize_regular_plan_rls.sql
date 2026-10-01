-- Jedna polityka odczytu planów zamiast nakładających się reguł admin/tutor.

drop policy if exists regular_lesson_plans_admin_all on public.regular_lesson_plans;
drop policy if exists regular_lesson_plans_tutor_select on public.regular_lesson_plans;

create policy regular_lesson_plans_select
on public.regular_lesson_plans
for select
to authenticated
using (
  (select public.is_admin())
  or exists (
    select 1 from public.tutors t
    where t.id = tutor_id
      and t.auth_user_id = (select auth.uid())
      and t.status = 'active'
  )
);

create policy regular_lesson_plans_admin_insert
on public.regular_lesson_plans
for insert
to authenticated
with check ((select public.is_admin()));

create policy regular_lesson_plans_admin_update
on public.regular_lesson_plans
for update
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

create policy regular_lesson_plans_admin_delete
on public.regular_lesson_plans
for delete
to authenticated
using ((select public.is_admin()));

drop policy if exists students_assigned_tutor_select on public.students;
drop policy if exists students_select on public.students;
create policy students_select
on public.students
for select
to authenticated
using (
  auth_user_id = (select auth.uid())
  or (select public.is_admin())
  or exists (
    select 1
    from public.regular_lesson_plans p
    join public.tutors t on t.id = p.tutor_id
    where p.student_id = students.id
      and p.status = 'active'
      and t.auth_user_id = (select auth.uid())
      and t.status = 'active'
  )
);
