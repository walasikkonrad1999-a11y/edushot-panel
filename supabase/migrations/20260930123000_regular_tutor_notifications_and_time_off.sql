-- Powiadomienia o stałych planach oraz połączenie urlopów z grafikiem stałym.

create or replace function public.edushot_notify_regular_plan_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tutor_user_id uuid;
  v_student_name text;
  v_day text;
begin
  select t.auth_user_id, s.name
  into v_tutor_user_id, v_student_name
  from public.tutors t
  join public.students s on s.id = new.student_id
  where t.id = new.tutor_id;

  if v_tutor_user_id is null then
    return new;
  end if;

  v_day := case new.weekday
    when 1 then 'poniedziałek'
    when 2 then 'wtorek'
    when 3 then 'środę'
    when 4 then 'czwartek'
    when 5 then 'piątek'
    when 6 then 'sobotę'
    else 'niedzielę'
  end;

  if tg_op = 'INSERT' and new.status = 'active' then
    insert into public.notifications (user_id, type, title, message)
    values (
      v_tutor_user_id,
      'regular_plan_assigned',
      'Nowy stały uczeń',
      'Przypisano Ci stałe zajęcia z uczniem ' || v_student_name ||
      ' w ' || v_day || ' o ' || to_char(new.start_time, 'HH24:MI') || '.'
    );
  elsif tg_op = 'UPDATE' and old.status = 'active' and new.status = 'ended' then
    insert into public.notifications (user_id, type, title, message)
    values (
      v_tutor_user_id,
      'regular_plan_ended',
      'Zmiana planu stałych zajęć',
      'Dotychczasowy plan zajęć z uczniem ' || v_student_name || ' został zakończony.'
    );
  end if;

  return new;
end;
$$;

drop trigger if exists regular_plan_notify_tutor on public.regular_lesson_plans;
create trigger regular_plan_notify_tutor
after insert or update of status on public.regular_lesson_plans
for each row execute function public.edushot_notify_regular_plan_change();

create or replace function public.edushot_prevent_overlapping_tutor_time_off()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.tutor_time_off existing
    where existing.tutor_id = new.tutor_id
      and existing.id is distinct from new.id
      and daterange(existing.date_from, existing.date_to, '[]') && daterange(new.date_from, new.date_to, '[]')
  ) then
    raise exception 'Ten zakres nakłada się na zapisaną nieobecność korepetytora.' using errcode = '23P01';
  end if;
  return new;
end;
$$;

drop trigger if exists tutor_time_off_no_overlap on public.tutor_time_off;
create trigger tutor_time_off_no_overlap
before insert or update on public.tutor_time_off
for each row execute function public.edushot_prevent_overlapping_tutor_time_off();

create or replace function public.edushot_sync_regular_lessons_with_time_off()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan_id uuid;
  v_reason text;
begin
  if tg_op = 'INSERT' then
    v_reason := 'Nieobecność korepetytora: ' || coalesce(nullif(btrim(new.reason), ''), 'brak podanego powodu');

    update public.regular_lesson_occurrences occurrence
    set status = 'conflict', reason = v_reason
    from public.lessons lesson
    where occurrence.lesson_id = lesson.id
      and occurrence.status = 'scheduled'
      and lesson.tutor_id = new.tutor_id
      and lesson.regular_plan_id is not null
      and lesson.lesson_date between new.date_from and new.date_to
      and lesson.start_at > now()
      and lesson.status in ('scheduled', 'confirmed');

    update public.lessons
    set operational_note = v_reason || ' — wymagane zastępstwo administratora.'
    where tutor_id = new.tutor_id
      and regular_plan_id is not null
      and lesson_date between new.date_from and new.date_to
      and start_at > now()
      and status in ('scheduled', 'confirmed');

    insert into public.notifications (user_id, type, title, message, lesson_id)
    select
      role_row.user_id,
      'regular_lesson_time_off',
      'Stała lekcja wymaga zastępstwa',
      tutor.name || ' zgłosił(a) nieobecność. Przydziel zastępstwo dla ucznia ' || lesson.student_name ||
        ' na ' || to_char(lesson.lesson_date, 'DD.MM.YYYY') || ' o ' || lesson.time_start || '.',
      lesson.id
    from public.lessons lesson
    join public.tutors tutor on tutor.id = lesson.tutor_id
    cross join public.user_roles role_row
    where role_row.role = 'admin'
      and lesson.tutor_id = new.tutor_id
      and lesson.regular_plan_id is not null
      and lesson.lesson_date between new.date_from and new.date_to
      and lesson.start_at > now()
      and lesson.status in ('scheduled', 'confirmed')
    on conflict do nothing;

    return new;
  end if;

  update public.regular_lesson_occurrences occurrence
  set status = 'scheduled', reason = null
  from public.lessons lesson
  where occurrence.lesson_id = lesson.id
    and occurrence.status = 'conflict'
    and occurrence.reason like 'Nieobecność korepetytora:%'
    and lesson.tutor_id = old.tutor_id
    and lesson.regular_plan_id is not null
    and lesson.lesson_date between old.date_from and old.date_to
    and lesson.start_at > now()
    and lesson.status in ('scheduled', 'confirmed')
    and not exists (
      select 1 from public.tutor_time_off other_leave
      where other_leave.tutor_id = old.tutor_id
        and lesson.lesson_date between other_leave.date_from and other_leave.date_to
    );

  update public.lessons lesson
  set operational_note = 'Lekcja wygenerowana z planu stałego.'
  where lesson.tutor_id = old.tutor_id
    and lesson.regular_plan_id is not null
    and lesson.lesson_date between old.date_from and old.date_to
    and lesson.start_at > now()
    and lesson.status in ('scheduled', 'confirmed')
    and lesson.operational_note like 'Nieobecność korepetytora:%'
    and not exists (
      select 1 from public.tutor_time_off other_leave
      where other_leave.tutor_id = old.tutor_id
        and lesson.lesson_date between other_leave.date_from and other_leave.date_to
    );

  for v_plan_id in
    select distinct plan.id
    from public.regular_lesson_plans plan
    where plan.tutor_id = old.tutor_id
      and plan.status = 'active'
      and exists (
        select 1
        from public.regular_lesson_occurrences occurrence
        where occurrence.plan_id = plan.id
          and occurrence.lesson_id is null
          and occurrence.status = 'skipped_time_off'
          and occurrence.occurrence_date between old.date_from and old.date_to
          and occurrence.occurrence_date >= current_date
          and not exists (
            select 1 from public.tutor_time_off other_leave
            where other_leave.tutor_id = old.tutor_id
              and occurrence.occurrence_date between other_leave.date_from and other_leave.date_to
          )
      )
  loop
    delete from public.regular_lesson_occurrences occurrence
    where occurrence.plan_id = v_plan_id
      and occurrence.lesson_id is null
      and occurrence.status = 'skipped_time_off'
      and occurrence.occurrence_date between old.date_from and old.date_to
      and occurrence.occurrence_date >= current_date
      and not exists (
        select 1 from public.tutor_time_off other_leave
        where other_leave.tutor_id = old.tutor_id
          and occurrence.occurrence_date between other_leave.date_from and other_leave.date_to
      );

    perform public.edushot_generate_regular_plan_lessons(v_plan_id, 90);
  end loop;

  return old;
end;
$$;

drop trigger if exists tutor_time_off_sync_regular_lessons on public.tutor_time_off;
create trigger tutor_time_off_sync_regular_lessons
after insert or delete on public.tutor_time_off
for each row execute function public.edushot_sync_regular_lessons_with_time_off();

revoke all on function public.edushot_notify_regular_plan_change() from public, anon, authenticated;
revoke all on function public.edushot_prevent_overlapping_tutor_time_off() from public, anon, authenticated;
revoke all on function public.edushot_sync_regular_lessons_with_time_off() from public, anon, authenticated;
grant execute on function public.edushot_notify_regular_plan_change() to service_role;
grant execute on function public.edushot_prevent_overlapping_tutor_time_off() to service_role;
grant execute on function public.edushot_sync_regular_lessons_with_time_off() to service_role;
