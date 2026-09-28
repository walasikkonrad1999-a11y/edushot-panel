revoke update on table public.lessons from anon, authenticated;

drop policy if exists lessons_update on public.lessons;

