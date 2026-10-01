-- The newer edushot_sync_payout_from_lesson trigger covers completed,
-- no-show and compensated late-cancellation flows. The legacy trigger
-- duplicated the same writes and had incomplete payable-status handling.
drop trigger if exists edushot_lesson_payout_sync on public.lessons;
drop function if exists public.edushot_sync_lesson_payout();
