create index if not exists notifications_lesson_id_idx
  on public.notifications (lesson_id);

create unique index if not exists notifications_event_dedupe_uidx
  on public.notifications (
    user_id,
    type,
    lesson_id,
    coalesce(message, '')
  )
  where lesson_id is not null;
