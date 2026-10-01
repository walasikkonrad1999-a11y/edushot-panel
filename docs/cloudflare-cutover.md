# Cloudflare — staging i bezpieczne przełączenie

## Konto docelowe

- konto: `Walasikkonrad1999@gmail.com's Account`
- account ID: `0426b1344f507ef14416ccb0ed781a1e`
- aktywna strefa: `edushot.pl`

Worker `edushot`, który obsługuje `edushot.pl` i `www.edushot.pl`, jest poza zakresem
wdrożenia paneli i nie może być modyfikowany podczas migracji.

## Darmowe adresy produkcyjne

| Element | Worker | Adres |
| --- | --- | --- |
| Panel | `panel` | `https://panel.edushot.workers.dev` |
| Admin API | `edushot-admin-api` | `https://edushot-admin-api.edushot.workers.dev` |
| Cal.com Sync | `edushot-calcom-sync` | `https://edushot-calcom-sync.edushot.workers.dev` |

Adresy `workers.dev` są docelowym, bezpłatnym środowiskiem paneli. Preview URLs
są wyłączone. Panel może nadpisać adresy API przez
`window.EDUSHOT_ADMIN_API_URL` i `window.EDUSHOT_SCHEDULER_API_URL`.

## Sekrety wymagane przed testami end-to-end

- `SUPABASE_SECRET_KEY` dla Admin API i Cal.com Sync,
- `CAL_API_KEY` dla Cal.com Sync,
- `CAL_WEBHOOK_SECRET` — ta sama wartość w Cal.com i Cal.com Sync.

Wartości nie mogą trafić do GitHuba ani do plików HTML.

## Kolejność przełączenia

1. Ustawić sekrety na nowych Workerach.
2. Zastosować wersjonowane migracje Supabase.
3. Wykonać testy end-to-end na `workers.dev`.
4. Ustawić URL webhooka w Cal.com na
   `https://edushot-calcom-sync.edushot.workers.dev/api/webhook/calcom`.
5. Powtórzyć test rezerwacji, anulowania, przełożenia i wypłaty.
6. Dopiero wtedy wyłączyć zasoby na starym koncie Cloudflare.
