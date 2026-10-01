-- PostgreSQL wymaga pełnego arbitra konfliktu dla ON CONFLICT (lesson_id).
-- Zwykły indeks UNIQUE nadal pozwala na wiele NULL-i dla korekt ręcznych.
drop index if exists public.guardian_billing_items_lesson_uidx;
create unique index guardian_billing_items_lesson_uidx
  on public.guardian_billing_items (lesson_id);
