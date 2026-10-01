-- EduSHOT: stały uczeń i dane kontaktowe rodzica/opiekuna.
-- Dokumenty i umowy pozostają poza systemem zgodnie z zakresem produktu.

alter table public.students
  add column if not exists student_kind text not null default 'booking',
  add column if not exists status text not null default 'active',
  add column if not exists started_on date,
  add column if not exists ended_on date,
  add column if not exists end_reason text,
  add column if not exists updated_at timestamptz not null default now();

alter table public.students drop constraint if exists students_student_kind_check;
alter table public.students
  add constraint students_student_kind_check
  check (student_kind in ('booking', 'regular'));

alter table public.students drop constraint if exists students_status_check;
alter table public.students
  add constraint students_status_check
  check (status in ('active', 'paused', 'ended'));

alter table public.students drop constraint if exists students_lifecycle_dates_check;
alter table public.students
  add constraint students_lifecycle_dates_check
  check (
    (status <> 'ended' and ended_on is null)
    or (status = 'ended' and ended_on is not null)
  );

create table if not exists public.guardians (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint guardians_name_not_blank check (btrim(name) <> ''),
  constraint guardians_contact_required check (
    nullif(btrim(coalesce(email, '')), '') is not null
    or nullif(btrim(coalesce(phone, '')), '') is not null
  )
);

create unique index if not exists guardians_email_lower_uidx
  on public.guardians (lower(email))
  where email is not null and btrim(email) <> '';

create index if not exists guardians_phone_idx
  on public.guardians (phone)
  where phone is not null and btrim(phone) <> '';

create table if not exists public.student_guardians (
  student_id uuid not null references public.students(id) on delete restrict,
  guardian_id uuid not null references public.guardians(id) on delete restrict,
  relationship text not null default 'parent',
  is_primary boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (student_id, guardian_id),
  constraint student_guardians_relationship_check
    check (relationship in ('parent', 'guardian'))
);

create unique index if not exists student_guardians_one_primary_uidx
  on public.student_guardians (student_id)
  where is_primary;

create index if not exists student_guardians_guardian_idx
  on public.student_guardians (guardian_id);

drop trigger if exists students_updated_at on public.students;
create trigger students_updated_at
before update on public.students
for each row execute function public.set_updated_at();

drop trigger if exists guardians_updated_at on public.guardians;
create trigger guardians_updated_at
before update on public.guardians
for each row execute function public.set_updated_at();

alter table public.guardians enable row level security;
alter table public.student_guardians enable row level security;

drop policy if exists guardians_admin_all on public.guardians;
create policy guardians_admin_all
on public.guardians
for all
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

drop policy if exists student_guardians_admin_all on public.student_guardians;
create policy student_guardians_admin_all
on public.student_guardians
for all
to authenticated
using ((select public.is_admin()))
with check ((select public.is_admin()));

revoke all on table public.guardians from public, anon;
revoke all on table public.student_guardians from public, anon;
grant select, insert, update on table public.guardians to authenticated;
grant select, insert, update on table public.student_guardians to authenticated;
grant select, insert, update, delete on table public.guardians to service_role;
grant select, insert, update, delete on table public.student_guardians to service_role;

create index if not exists students_kind_status_idx
  on public.students (student_kind, status);

comment on column public.students.student_kind is
  'booking = uczeń z rezerwacji jednorazowej, regular = stały uczeń dodany przez administratora.';
comment on column public.students.status is
  'Status organizacyjny ucznia; zakończenie współpracy nigdy nie usuwa historii.';
