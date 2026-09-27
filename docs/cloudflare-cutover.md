# Cloudflare — staging i bezpieczne przełączenie

## Konto docelowe

- konto: `Walasikkonrad1999@gmail.com's Account`
- account ID: `0426b1344f507ef14416ccb0ed781a1e`
- aktywna strefa: `edushot.pl`

Worker `edushot`, który obsługuje `edushot.pl` i `www.edushot.pl`, jest poza zakresem
wdrożenia paneli i nie może być modyfikowany podczas migracji.

## Środowisko testowe

| Element | Worker | Adres testowy |
| --- | --- | --- |
| Panel | `panel` | `https://panel.walasikkonrad1999.workers.dev` |
| Admin API | `edushot-admin-api` | `https://edushot-admin-api.walasikkonrad1999.workers.dev` |
| Cal.com Sync | `edushot-calcom-sync` | `https://edushot-calcom-sync.walasikkonrad1999.workers.dev` |

Adresy `workers.dev` są włączone wyłącznie do testów. Preview URLs są wyłączone.
Panel testowy ustawia adresy API przez `window.EDUSHOT_ADMIN_API_URL` i
`window.EDUSHOT_SCHEDULER_API_URL`, bez zmiany kodu produkcyjnego.

## Sekrety wymagane przed testami end-to-end

- `SUPABASE_SECRET_KEY` dla Admin API i Cal.com Sync,
- `CAL_API_KEY` dla Cal.com Sync,
- `CAL_WEBHOOK_SECRET` — ta sama wartość w Cal.com i Cal.com Sync.

Wartości nie mogą trafić do GitHuba ani do plików HTML.

## Docelowe domeny

- `panel.edushot.pl` → `panel`,
- `admin-api.edushot.pl` → `edushot-admin-api`,
- `sync.edushot.pl` → `edushot-calcom-sync`.

Domeny należy przypiąć dopiero po poprawnym teście logowania, tworzenia i
dezaktywowania korepetytora, dostępności, nieobecności, webhooków oraz wypłat.

## Kolejność przełączenia

1. Ustawić sekrety na nowych Workerach.
2. Zastosować wersjonowane migracje Supabase.
3. Wykonać testy end-to-end na `workers.dev`.
4. Przypiąć trzy docelowe subdomeny.
5. Zmienić URL webhooka w Cal.com na `https://sync.edushot.pl/api/webhook/calcom`.
6. Powtórzyć test rezerwacji, anulowania, przełożenia i wypłaty.
7. Dopiero wtedy wyłączyć zasoby na starym koncie Cloudflare.
