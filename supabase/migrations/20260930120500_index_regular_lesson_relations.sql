create index if not exists lessons_original_tutor_id_idx
  on public.lessons (original_tutor_id)
  where original_tutor_id is not null;

create index if not exists regular_occurrences_lesson_id_idx
  on public.regular_lesson_occurrences (lesson_id)
  where lesson_id is not null;

create index if not exists regular_occurrences_original_tutor_id_idx
  on public.regular_lesson_occurrences (original_tutor_id)
  where original_tutor_id is not null;

create index if not exists regular_plan_breaks_created_by_idx
  on public.regular_plan_breaks (created_by)
  where created_by is not null;
