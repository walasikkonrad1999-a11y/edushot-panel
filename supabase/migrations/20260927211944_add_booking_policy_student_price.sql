-- EduSHOT: pole ceny ucznia wymagane przez Worker synchronizacji Cal.com.
-- Migracja jest bezpieczna dla istniejących danych i może być uruchamiana ponownie.

alter table public.booking_policy
  add column if not exists student_price numeric(10, 2) not null default 70.00;
