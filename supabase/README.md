# Supabase

Projekt produkcyjny: `lmcebpymlekptqowofyg` (`Korepetytorzy`).

Obecny schemat został utworzony bez historii migracji. Zanim powstaną migracje naprawcze, należy zapisać kontrolowany stan bazowy, a następnie dodawać małe, odwracalne migracje. Nie wolno odtwarzać całego schematu bezpośrednio na produkcji.

Pierwszy pakiet migracji będzie obejmował:

1. ujednolicenie `tutor_time_off` z panelami i Cal.com,
2. naprawę funkcji `mark_payout_paid` oraz zapisu audytu,
3. konsolidację nakładających się triggerów finansowych,
4. ograniczenie wykonywania funkcji do właściwych ról,
5. utwardzenie `search_path`, RLS i brakujących indeksów,
6. przeniesienie stawek z kodu do jednej polityki konfiguracyjnej.

Każda migracja wymaga testu na kopii/stagingu oraz ponownego uruchomienia doradców bezpieczeństwa i wydajności przed wdrożeniem produkcyjnym.

