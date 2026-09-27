# EduSHOT — panel administratora i korepetytora

Repozytorium zawiera wyłącznie zaplecze pracownicze EduSHOT:

- panel administratora,
- panel korepetytora,
- Admin API,
- synchronizację Cal.com → Supabase.

Panel ucznia i główna strona publiczna nie należą do tego zakresu. Obecne wdrożenia produkcyjne pozostają bez zmian do czasu zakończenia testów i zatwierdzenia przełączenia.

## Docelowa architektura

Każdy element jest oddzielnym wdrożeniem Cloudflare Workers na jednym, głównym koncie:

| Katalog | Worker | Odpowiedzialność |
| --- | --- | --- |
| `apps/panel` | `panel` | statyczny panel `/admin` i `/tutor` |
| `workers/admin-api` | `edushot-admin-api` | operacje administratora wymagające klucza sekretnego |
| `workers/calcom-sync` | `edushot-calcom-sync` | webhooki i synchronizacja Cal.com z Supabase |

Docelowe adresy produkcyjne:

- `https://panel.edushot.pl` — panel administratora i korepetytora,
- `https://admin-api.edushot.pl` — operacje administracyjne,
- `https://sync.edushot.pl` — Cal.com Sync i webhook.

Główna strona `https://edushot.pl` oraz `https://www.edushot.pl` pozostaje osobnym Workerem i nie jest modyfikowana przez konfiguracje panelu.

Kod Workerów nie może znajdować się w katalogu statycznych zasobów panelu. Dzięki temu źródła API ani pliki konfiguracyjne nie są publicznie serwowane.

## Sekrety i konfiguracja

Prawdziwych kluczy nie zapisujemy w GitHubie. Lokalne nazwy zmiennych pokazują pliki `.dev.vars.example`, a wartości produkcyjne należy ustawić jako sekrety konkretnego Workera w Cloudflare.

Minimalny zestaw:

- Supabase: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`;
- Cal.com Sync: dodatkowo `CAL_API_KEY` oraz — po włączeniu podpisywania webhooków — `CAL_WEBHOOK_SECRET`;
- Admin API: `TUTOR_INVITE_REDIRECT` i `ALLOWED_ORIGINS` są zwykłą konfiguracją, nie sekretami.

Klucz `SUPABASE_SECRET_KEY` może występować wyłącznie po stronie Workerów. Nie wolno umieszczać go w HTML-u panelu.

## Bezpieczne wdrażanie

1. Zmiany powstają na osobnej gałęzi i przechodzą przegląd.
2. Najpierw wykonywane są testy lokalne i na środowisku testowym.
3. Migracje Supabase są wersjonowane i testowane przed wdrożeniem.
4. Produkcja jest przełączana dopiero po akceptacji testów.
5. Zasoby na starym koncie Cloudflare są usuwane dopiero po potwierdzeniu, że nowe adresy i webhooki działają.

## Stan fundamentów

Ta gałąź porządkuje strukturę projektu i konfigurację wdrożeń. Nie wdraża jeszcze zmian do Cloudflare ani Supabase i nie zmienia istniejących adresów produkcyjnych.
