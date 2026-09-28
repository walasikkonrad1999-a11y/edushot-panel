-- lesson_finance_admin_all already grants administrators every operation.
-- Tutors use get_my_lesson_earnings(), so the separate SELECT policy is both
-- redundant and an unnecessary extra policy evaluation.
drop policy if exists lesson_finance_select on public.lesson_finance;

