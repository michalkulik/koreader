# Plan: półka zsynchronizowana między urządzeniami (Kindle-like)

Cel: użytkownik otwiera książkę w KOReaderze, książka i postęp trafiają na własny serwer, a na innym urządzeniu (Android, Linux, jailbreakowany Kindle 10 / KindleBasic4) można ją otworzyć w tym samym miejscu. Dziś funkcje są rozproszone między `kosync` (postęp) i `cloud storage` (pliki), bez wspólnego modelu książki i półki.

Zakres obejmuje też **profil ustawień przypisany do konta** (gesty, czcionki, UI, domyślne ustawienia czytnika), żeby skonfigurować KOReadera raz i zaciągnąć konfigurację na inne urządzenie.

Zasady:

- **Offline-first** — każda operacja najpierw do lokalnej kolejki, sync kiedy sieć jest dostępna.
- **Manualny sync jest funkcją pierwszorzędną**, szczególnie na Kindle; automatyczny jest tylko „best effort”.
- **Bez pełnego hashowania dużych plików na Kindle** — SHA-256 liczy serwer podczas uploadu.
- **Kompatybilność z kosync** — ten sam serwer obsługuje stary protokół postępu.

---

## 1. Wykorzystywane elementy KOReadera

| Funkcja | Gdzie | Co daje |
|---|---|---|
| Progress sync | `plugins/kosync.koplugin/` (`KOSyncClient.lua`, `api.json`) | protokół `users/auth`, `syncs/progress`, `partial_md5_checksum`, kolejka offline |
| Cloud storage | `plugins/cloudstorage.koplugin/providers/webdav.lua` | streaming upload/download, ETag |
| Pobieranie i otwieranie | `plugins/opds.koplugin/main.lua` | progres pobierania, „Read now” |
| Kolekcje | `frontend/readcollection.lua`, `frontend/apps/filemanager/filemanagercollection.lua` | lokalne półki w `settings/collection.lua` |
| Sieć / Wi-Fi | `frontend/ui/network/manager.lua` | `willRerunWhenOnline`, `beforeWifiAction`, obsługa Kindle |
| Aktualizacje | `frontend/ui/otamanager.lua` | OTA dla Androida i Kindla |

Brakuje wspólnego modelu `książka + plik + postęp + półka` po stronie serwera oraz klienta, który traktuje to jako całość.

---

## 2. Architektura

```
KOReader (Kindle / Android / Linux)
  └─ plugin shelfsync.koplugin
       ├─ lokalny indeks książek + kolejka operacji (JSON/SQLite)
       ├─ klient HTTP (JSON + streaming plików)
       ├─ synchronizacja ustawień (gesty, czcionki, UI) + czcionki własne
       └─ UI półki (lista, okładki, „Czytaj dalej”, ręczny sync)
                    │ HTTPS
                    ▼
        Caddy / Nginx Proxy Manager (TLS)
                    │
                    ▼
        koreader-shelf (Docker, FastAPI/Go)
          ├─ SQLite (WAL) lub Postgres
          ├─ /data/books/<hash>.<ext>
          ├─ /data/covers/<book_id>.jpg
          ├─ /data/settings/<user>/<group>.json (wersjonowane)
          ├─ /data/fonts/<sha256>.<ttf|otf>
          └─ worker: okładki, metadane, sprzątanie
```

Serwer jest źródłem prawdy dla biblioteki; postęp to last-writer-wins z numerem rewizji; urządzenie jest offline-first.

---

## 3. Tożsamość książki i deduplikacja

- **`partial_md5_checksum`** — już liczony przez KOReader; standard kosync. Używany jako `doc_id` dla postępu, dzięki czemu stary kosync i nowa półka dzielą dane.
- **`content_sha256`** — liczony **na serwerze** podczas streamowanego uploadu. Klient wysyła `size`, `partial_md5`, `filename`; serwer liczy SHA-256 i po zakończeniu robi `rename`. Kindle 10 nie mieli dużych plików.
- **`book_id`** — UUID serwera. Jeden plik = jedna książka (v1); grupowanie EPUB/MOBI po metadanych w v2.
- Metadane: `doc_props` (tytuł, autor, seria, język, ISBN) wysyłane przy pierwszym otwarciu.
- Okładki: generowane serwerowo (Calibre / `ebook-meta` / `pdftoppm`) lub wysyłane przez klienta; na Kindle preferowany serwer.

---

## 4. Serwer w Dockerze

### Compose (v1, single-user)

```yaml
services:
  shelf:
    image: ghcr.io/michalkulik/koreader-shelf:latest
    environment:
      PUBLIC_URL: https://shelf.mkulik.eu
      DATABASE_URL: sqlite:////data/shelf.db
      BOOKS_DIR: /data/books
      COVERS_DIR: /data/covers
      AUTH_SECRET: ${AUTH_SECRET}
      MAX_UPLOAD_MB: "512"
    volumes:
      - shelf-data:/data
    restart: unless-stopped
    # TLS: istniejący NPM/Caddy na oracle3

volumes:
  shelf-data:
```

SQLite w trybie WAL wystarczy dla jednego użytkownika. Postgres/MinIO dopiero przy wielu użytkownikach lub dużym ruchu. Backup: `restic`/`borg` katalogu `/data`.

### API (v1)

```
POST /api/v1/auth/token        {username,password} -> {token,device_id}
GET  /api/v1/sync?cursor=...   -> {books:[...],collections:[...],cursor,server_time}
POST /api/v1/books             {partial_md5,size,filename,metadata} -> {book_id}
PUT  /api/v1/books/{id}/file   (stream; serwer liczy sha256)
GET  /api/v1/books/{id}/file   (Range: bytes=...)
GET  /api/v1/books/{id}/cover
PUT  /api/v1/books/{id}/progress {position,percentage,device_id,base_rev}
GET  /api/v1/books/{id}/progress
PUT  /api/v1/books/{id}/metadata
GET/PUT /api/v1/collections

GET  /api/v1/settings                     -> {schema, groups:{...}, updated_at}
PUT  /api/v1/settings/{group}             {base_rev,data,device_class} -> {rev} | 409
GET  /api/v1/settings/revisions           -> ostatnie N wersji (rollback)
POST /api/v1/settings/revisions/{rev}/restore
GET  /api/v1/fonts                        -> manifest czcionek własnych
PUT  /api/v1/fonts/{sha256}               (upload pliku czcionki)
GET  /api/v1/fonts/{sha256}               (download)
```

Kompatybilność z kosync na tym samym serwerze:

```
GET /users/auth
PUT /syncs/progress
GET /syncs/progress/:document
```

Dzięki temu istniejący plugin `kosync` działa po zmianie „Custom sync server”, a nowy plugin dokłada półkę i pliki.

### Model danych (minimum)

```
users(id, username, password_hash)
devices(id, user_id, name, last_seen)
books(id, content_sha256, partial_md5, size, filename, title, authors, series,
      language, cover, created_at)
user_books(user_id, book_id, added_at, removed_at, last_opened_at, pin_offline)
progress(user_id, book_id, device_id, position, percentage, rev, updated_at)
collections(id, user_id, name, updated_at)
collection_books(collection_id, book_id, added_at)
uploads(id, user_id, book_id, received_bytes, status)

settings_groups(user_id, group, rev, data_json, updated_at, updated_by_device)
settings_revisions(id, user_id, group, rev, data_json, created_at)
fonts(id, user_id, sha256, filename, size, created_at)
```

`rev` rośnie przy każdym zapisie postępu; `PUT` z nieaktualnym `base_rev` zwraca `409` i stan serwera — klient decyduje o konflikcie.

---

## 5. Klient: `plugins/shelfsync.koplugin`

```
plugins/shelfsync.koplugin/
  main.lua        -- hooki, menu, akcja dispatchera, UI półki
  client.lua      -- HTTP/JSON + streaming (socket.http, ltn12, socketutil)
  queue.lua       -- trwała kolejka operacji (JSON w settings/)
  index.lua       -- mapowanie ścieżka lokalna <-> book_id
  progress.lua    -- odczyt/zapis pozycji (rolling/paging)
  settings_sync.lua -- allowlist, diff, eksport/import ustawień, czcionki
  ui.lua          -- lista półki, pasek statusu, long-press
```

### Hooki

- `onReaderReady` — pobierz postęp; jeśli nowszy, zaproponuj przejście do pozycji.
- `onPageUpdate` — push co N stron (domyślnie 5), z debounce.
- `onCloseDocument`, `onSuspend` — wymuś push; przy braku sieci zostaw w kolejce.
- `onResume`, `onNetworkConnected` — flush kolejki i pull zmian.
- `onFlushSettings` — zapis kolejki/indeksu.

### Przepływy

1. **Otwarcie książki**
   - `partial_md5` jest w indeksie i na serwerze: pobierz postęp, porównaj `rev`, ewentualnie zapytaj o konflikt.
   - brak na serwerze: jeśli opcja „Wysyłaj przy otwarciu” włączona, dodaj upload do kolejki. Na Kindle najpierw pytanie „Wysłać na półkę? Włączyć Wi-Fi?”.
2. **Zamknięcie / suspend** — push postępu z krótkim timeoutem; niewysłana książka trafia do kolejki.
3. **Nowe urządzenie** — `GET /sync` pobiera bibliotekę, okładki, postępy i kolekcje. Tap:
   - lokalna kopia istnieje: otwórz i zsynchronizuj pozycję,
   - brak: pobierz do `download_dir`, zweryfikuj SHA-256, otwórz.
4. **Konflikt** — serwer zwraca `409`; domyślnie nowszy `updated_at`, przy bliskich czasach pytanie. `base_rev` zapobiega ping-pongowi.

---

## 6. Synchronizacja ustawień (gesty, czcionki, UI)

Cel: ustawić KOReadera na jednym urządzeniu i zaciągnąć te ustawienia na inne, jako część tego samego konta na serwerze. To nie jest synchronizacja postępu ani ustawień konkretnej książki — to **profil użytkownika**.

### Co synchronizujemy

| Grupa | Przykłady | Źródło | Domyślnie |
|---|---|---|---|
| `ui` | język, motyw, rozmiar UI, fallbacki czcionek UI, sortowanie menu | `G_reader_settings` (`settings.reader.lua`) | tak |
| `reader` | domyślna czcionka, rozmiar, interlinia, marginesy, hyphenacja, pasek statusu | `G_reader_settings` + defaults | tak (bez DPI i podświetlenia) |
| `gestures` | przypisania gestów, progi czasowe, `ignore_hold_corners`, `ges_*` | `settings/gestures.lua` + `G_reader_settings` | tak, z walidacją akcji |
| `profiles` | profile, hotkeys, akcje dispatchera | `settings/profiles.lua`, `settings/hotkeys.lua` | opcjonalnie |
| `collections` | nazwy półek i przypisania książek | `settings/collection.lua` | opcjonalnie (etap późniejszy) |
| `fonts` | pliki czcionek własnych użytkownika | katalog `fonts/` | opcjonalnie, ręcznie |

**Nie synchronizujemy** (denylist):

- sekretów: `userkey`, hasła, tokeny, dane cloud storage, klucze API,
- tożsamości urządzenia: `device_id`, `lastdir`, `home_dir`, ścieżki, `ota_server`,
- sieci: Wi-Fi, proxy, DNS,
- ekranu: DPI, rotacja, fullscreen, frontlight/warmth,
- ustawień per dokument: `docsettings`, postęp, zakładki, wyróżnienia, statystyki,
- cache'y, `defaults.custom.lua`, plików systemowych i czcionek systemowych (prawa autorskie).

### Zasady

- **Allowlist, nie cały plik ustawień** — serwer dostaje tylko wybrane klucze z wersjonowanym `schema_version`.
- **Rewizje per grupa** — `PUT` z `base_rev`; przy niezgodności `409` i stan serwera. Ostatnie 10 wersji trzymamy do rollbacku.
- **Podgląd różnic przed pobraniem** — lista zmienionych grup i kluczy (z nazwami czytelnymi dla znanych ustawień).
- **Backup przed zastosowaniem** — kopia bieżących plików ustawień (np. `settings.backup-<timestamp>.tar.gz`).
- **Zastosowanie przy starcie + restart** — zapis plików `LuaSettings`, potem `UIManager:askForRestart()`. Nie aplikujemy ustawień „na żywo”, żeby uniknąć połowicznego stanu.
- **Walidacja gestów** — akcje dispatchera sprawdzane względem aktualnej wersji KOReadera; nieznane akcje są pomijane z ostrzeżeniem (różne wersje pluginów).
- **Czcionki** — dopasowanie po nazwie pliku; jeśli czcionki nie ma, fallback + ostrzeżenie. Pliki własne wysyłane jako assety po `sha256` (tylko na żądanie, przez Wi-Fi).
- **Profil urządzenia** — `device_class` (`kindle-basic4`, `android-arm64`, `linux`) pozwala na nakładki: np. gesty tylko na dotykowych, inne fallbacki czcionek, inne skróty sprzętowe. Domyślnie jeden wspólny profil.
- **Automatyczność** — push po zmianie opcjonalny (debounce ~30 s, kolejka offline); **pull tylko ręcznie** albo przy pierwszym logowaniu na nowym urządzeniu, bo wymaga restartu.

### Przepływy

1. **Wysłanie ustawień**
   - zbierz allowlistę z `G_reader_settings` i plików `settings/*.lua`,
   - zserializuj do canonical JSON (stabilna kolejność kluczy),
   - `PUT /api/v1/settings/{group}` z `base_rev`,
   - zapisz `last_synced_rev` i czas.
2. **Pobranie ustawień**
   - `GET /api/v1/settings` → porównaj rewizje grup,
   - pokaż „Zmienią się: Wygląd (3), Gesty (12), Czcionki (1)”,
   - po potwierdzeniu: backup → zapis plików → ewentualne pobranie czcionek → restart.
3. **Nowe urządzenie (onboarding)**
   - logowanie do konta na serwerze,
   - propozycja „Pobierz ustawienia z konta?”,
   - wybór profilu urządzenia (domyślnie wykryty),
   - zastosowanie i restart.
4. **Konflikt**
   - pokaż grupy z różnymi rewizjami i daty,
   - wybór: „Zostaw lokalne / Weź z serwera / Podejrzyj różnice / Później”,
   - po wyborze zapis z nowym `rev`.

### UI

`Ustawienia → Synchronizacja → Ustawienia`:

```
Konto: michal@serwer          [ Wyloguj ]
Ostatnia synchronizacja: 2 dni temu · serwer rev 14
Profil urządzenia: Kindle Basic 4

[ ✓ ] Wygląd i czcionki UI
[ ✓ ] Domyślne ustawienia czytnika
[ ✓ ] Gesty
[   ] Profile i skróty
[   ] Kolekcje
[   ] Czcionki własne

[ Wyślij teraz ]  [ Pobierz teraz ]  [ Podejrzyj różnice ]
[ ] Automatycznie wysyłaj zmiany
```

Na Kindle dodatkowo: ostrzeżenie, że pobranie ustawień wymaga restartu KOReadera i ewentualnego włączenia Wi-Fi.

### Implementacja

- `plugins/shelfsync.koplugin/settings_sync.lua`:
  - `ALLOWLIST` / `DENYLIST` per grupa,
  - `export_group()`, `import_group()`, `diff_groups()`,
  - backup i rollback,
  - walidacja akcji gestów przez `Dispatcher`,
  - obsługa czcionek przez `DataStorage` / `ffiUtil`.
- `plugins/shelfsync.koplugin/client.lua`: endpointy settings/fonts.
- `plugins/shelfsync.koplugin/main.lua`: menu, onboarding, hook `onFlushSettings` (auto-push).
- `frontend/ui/elements/common_settings_menu_table.lua` lub menu wtyczki: wejście do synchronizacji ustawień.
- Zapis: `LuaSettings` (`settings.reader.lua`, `gestures.lua`, `profiles.lua`, `collection.lua`), `flush()` po imporcie.
- Restart: `UIManager:askForRestart()`.

### Testy

- round-trip eksport → import na drugim urządzeniu,
- allowlist nie przepuszcza sekretów ani ścieżek,
- diff pokazuje właściwe grupy,
- konflikt `409` nie nadpisuje nowszej wersji,
- nieznana akcja gestu jest pomijana,
- brak czcionki → fallback + ostrzeżenie,
- rollback do poprzedniej rewizji,
- dwa urządzenia naprzemiennie zmieniające ustawienia,
- migracja `schema_version`.

---

## 7. UI półki i ręczny sync

Pasek stanu na górze ekranu biblioteki:

```
Półka                          [ ⟳ Synchronizuj ]
Ostatnia synchronizacja: 2 min temu · 3 zmiany w kolejce
```

- **`⟳ Synchronizuj`** — pełny sync na żądanie.
- Podpis: czas ostatniego udanego syncu + liczba oczekujących operacji.
- Błędy: „1 błąd — dotknij, aby zobaczyć szczegóły”.
- Osobny wpis: **„Wyślij książki z tego urządzenia”**.

### Sekwencja ręcznego syncu

1. Sprawdź sieć:
   - Android/Linux: `NetworkMgr:willRerunWhenOnline()`.
   - Kindle: `ConfirmBox` „Włączyć Wi-Fi i zsynchronizować?”; po syncu przywróć poprzedni stan (`NetworkMgr:beforeWifiAction`).
2. Wyślij lokalne zmiany: postępy, metadane/okładki, kolekcje.
3. Wyślij oczekujące pliki z kolejki (progres per książka).
4. Pobierz zmiany przez `GET /sync?cursor=...`.
5. Rozwiąż konflikty (`409`): „Zostaw lokalny / Weź z serwera / Później”.
6. Odśwież półkę, zapisz nowy `cursor` i czas syncu.

Całość w korutynie (`Trapper:wrap`), z `ProgressbarDialog`/`InfoMessage`, możliwością anulowania. Na czas transferu zablokuj autostandby. E-ink: jedno odświeżenie na start i jedno na koniec.

Po zakończeniu konkretny raport zamiast „OK”:

```
Zsynchronizowano.
Postępy: 2 · Wysłano książki: 1 · Nowe książki: 3
Błędy: 1 (dotknij)
```

Błąd sieci nie czyści kolejki. Operacje są idempotentne (dedupe po `partial_md5` / `content_sha256`, postęp nie nadpisuje nowszego `rev`).

### Sync per książka (long-press)

- **Synchronizuj tę książkę** — tylko postęp + plik.
- **Wyślij na serwer** — dla książki lokalnej.
- **Pobierz** / **Usuń lokalną kopię** — zarządzanie miejscem na Kindle.
- **Otwórz mimo to** — gdy plik jest lokalny, a sync się nie udał.

### Dodatkowe wejścia

- Dispatcher/gest: akcja „Synchronizuj półkę”.
- Menu wtyczki: „Synchronizuj teraz”, „Pokaż kolejkę”, „Ostatnie błędy”, „Ustawienia synchronizacji”.
- Automatycznie: otwarcie półki, zamknięcie książki, suspend, powrót sieci — bez wymuszania Wi-Fi, z krótkim timeoutem, cicho do kolejki.

---

## 8. Kindle 10 (KindleBasic4) — wymagania

- **Brak tła** — brak ciągłego połączenia w uśpieniu; sync tylko przy otwarciu półki, resume, zamknięciu książki i suspendzie. Na Androidzie można dodać WebSocket/SSE tylko gdy aplikacja jest na wierzchu.
- **Wi-Fi na żądanie** — `Device:hasWifiToggle`, `NetworkMgr:turnOnWifiAndWaitForConnection`, `NetworkMgr:beforeWifiAction`; przywróć poprzedni stan.
- **CPU/RAM** — zero pełnego hashowania na kliencie, streaming download/upload, brak ładowania całej książki do RAM, okładki tylko w rozmiarze miniatury.
- **Stary TLS** — poprawny certyfikat Let's Encrypt, TLS 1.2; test na urządzeniu.
- **Ścieżki** — download do `/mnt/us/documents/koreader-shelf/` lub katalogu użytkownika; `Device:isValidPath`.
- **Formaty** — bez DRM (EPUB/MOBI/AZW3/PDF); książki z DRM się nie zsynchronizują.

---

## 9. Aktualizacje aplikacji — źródło: fork na GitHubie

**Stan:** zaimplementowane w `v2026.14`, poprawki w `v2026.15` i `v2026.16`. `frontend/ui/otamanager.lua` nie ma już
serwerów upstream — `ota_servers[1]` wskazuje na wydania forka:

```lua
ota_servers = {
    "https://github.com/michalkulik/koreader/releases/latest/download/",
}
```

Na Androidzie `Device:otaModel()` zwraca `android-arm64` + typ `link`: pobierany
jest `koreader-android-arm64-latest-stable` (pierwsza linia = nazwa APK), potem
APK i `android.ota.install()`. GitHub odpowiada na `/releases/latest/download/<plik>`
przekierowaniem 302, więc `OTAManager` dostał funkcję
`fetch_text_follow_redirects()`, która podąża za 301/302/303/307/308 (LuaSocket
sam tego nie robi). Manifest może też zawierać pełny URL zamiast nazwy pliku.

### Co zawiera wydanie

Do każdego wydania Android dołączane są trzy assety:

1. `koreader-android-arm64-vYYYY.MM.apk` — podpisany APK,
2. `koreader-android-arm64-latest-stable` — manifest dla wbudowanego OTA
   (pierwsza linia = nazwa APK z punktu 1),
3. `latest.json` — metadane dla przyszłych klientów:

```json
{
  "version": "v2026.16",
  "versionCode": 202616000000,
  "url": "https://github.com/michalkulik/koreader/releases/download/v2026.16/koreader-android-arm64-v2026.16.apk",
  "sha256": "…",
  "size": 30154383,
  "abi": "arm64-v8a",
  "filename": "koreader-android-arm64-v2026.16.apk"
}
```

Assety generuje `tools/make-ota-assets.py`:

```sh
tools/make-ota-assets.py --apk koreader-android-arm64-v2026.16.apk \
    --version v2026.16 --out /tmp/opencode/ota-assets
```

i dołącza `tools/release-android.sh` (albo ręcznie `gh release upload --clobber`).

### Ograniczenia

- Wbudowany OTA weryfikuje tylko **podpis APK** (PackageInstaller). `latest.json`
  zawiera `sha256`, ale obecny przepływ `link` go nie sprawdza — pełna weryfikacja
  sumy kontrolnej to przyszły krok.
- Wpisy „Update server” pokazują teraz wyłącznie feed forka; stary zapisany serwer
  upstream jest migrowany automatycznie w `getOTAServer()`.
- Kindle: KOReader używa `kotasync` i modelu `kindlepw2`. Dla aktualizacji
  z forka trzeba publikować `koreader-kindlepw2-latest-stable.kotasync` +
  `update.tar.xz`; inaczej ręczne kopiowanie (etap 6/7 dla Kindle).
- Każda aktualizacja podpisana tym samym kluczem `koreader-release.jks`
  (PackageInstaller odrzuci inny podpis). Klucz i `credentials.txt` w backupie.

---

## 10. Etapy wdrożenia

1. **Serwer v1** — auth, biblioteka, upload/download, postęp, kosync-compat, Docker + testy. ✅ **ukończony 2026-10-20** (szczegóły w §12).
2. **Plugin v1** — kolejka, indeks, sync postępu, upload przy otwarciu, download z półki. 🚧 **w toku (2026-10-20)** — kod w §12, etap 2.
3. **UI półki** — lista, „Czytaj dalej”, status offline, sortowanie, long-press, ręczny sync. ✅ **ukończony 2026-10-20** (okładki odłożone do etapu serwerowego – patrz §12).
4. **Ustawienia** — profil ustawień na koncie: UI/czytnik/gesty, podgląd różnic, backup, rollback, czcionki własne.
5. **Kolekcje** — dwukierunkowa synchronizacja z `collection.lua`.
6. **Kindle tuning** — Wi-Fi, streaming, limity, testy na KindleBasic4.
7. **OTA** — feed na forku, manifest + `latest.json`, wpis „Źródło aktualizacji”. ✅ **Android/`link` ukończony 2026-10-20**; `kotasync` dla Kindle do etapu 6.

---

## 11. Ryzyka

- **Brak prawdziwego pusha na Kindle** — „natychmiast” dotyczy tylko otwartej aplikacji na Androidzie; na Kindle sync przy zdarzeniach lub ręcznie.
- **Duże pliki** — limit uploadu, streaming; resumable upload w v2.
- **DRM / prawa autorskie** — synchronizujemy tylko pliki użytkownika.
- **Rozjazd wersji silnika** — xpointer może się różnić między wersjami KOReadera; trzymać podobne wersje na urządzeniach.
- **Bezpieczeństwo** — HTTPS, token per urządzenie, rate limit, brak dostępu do plików bez auth.
- **Podpis APK** — zmiana klucza wymusza odinstalowanie aplikacji; klucz trzeba chronić i backupować.
- **Ustawienia a różnice urządzeń** — DPI, podświetlenie, sprzętowe klawisze i dostępność czcionek mogą się różnić; dlatego allowlist + profil urządzenia, nigdy ślepe kopiowanie całego `settings.reader.lua`.
- **Ustawienia a sekrety** — `userkey`, hasła, tokeny i dane sieci muszą być twardo wykluczone; test jednostkowy pilnujący denylisty.
- **Restart po imporcie** — na Kindle restart jest odczuwalny; pobieranie ustawień tylko ręcznie/na onboardingu, nie automatycznie przy każdym starcie.
- **Zgodność akcji gestów** — nazwy akcji dispatchera zmieniają się między wersjami; nieznane akcje pomijane, nigdy nie wywalają importu.
- **Czcionki** — synchronizujemy tylko pliki własne użytkownika; czcionki systemowe i licencjonowane pozostają lokalne, brak pliku → fallback.

---

## 12. Postęp wdrożenia

### Etap 1 — serwer v1 (2026-10-20) ✅

**Repozytorium:** <https://github.com/michalkulik/koreader-server> (prywatne, tag `v0.1.0`, commit `ab208c1`).

**Obraz Dockera:** `ghcr.io/michalkulik/koreader-server:0.1.0` (oraz `:latest`).

**Wdrożenie:**
- host: `ubuntu` (192.168.69.11),
- Portainer: stack `koreader-server` (Id 73, endpoint 3), kontener `koreader-server`,
- port: `8099` → `8080` w kontenerze,
- dane: `/srv/koreader-server/data` (`shelf.db` + `books/`), właściciel `10001:10001`,
- healthcheck: `GET /health` → `{"status":"ok"}`,
- konto testowe: `michal` (hasło poza repozytorium, plik `600` na hp:
  `/root/.local/share/koreader-server/credentials.txt`).

**Zaimplementowane endpointy:**
- konta: `POST /api/v1/auth/register`, `POST /api/v1/auth/token`,
  `GET /api/v1/me`, `POST /api/v1/auth/logout`,
- kosync: `POST /users/create`, `GET /users/auth`,
  `PUT /syncs/progress`, `GET /syncs/progress/:document`,
- biblioteka: `POST /api/v1/books`, `GET /api/v1/books`,
  `GET /api/v1/books/{id}`, `PUT /api/v1/books/{id}/file`,
  `GET /api/v1/books/{id}/file` (Range), `DELETE /api/v1/books/{id}`,
- postęp: `GET/PUT /api/v1/books/{id}/progress` (`base_rev`, konflikt `409`),
- sync przyrostowy: `GET /api/v1/sync?cursor=...`,
- `GET /health`, `GET /api/v1/info`.

**Testy:** `pytest -q` → 7 passed (rejestracja/logowanie, kosync, upload/download/Range,
dedupe po `partial_md5`, zgodność rozmiaru, rewizje i konflikt postępu, auth).

**Uwagi:**
- Etap 1 nie ma jeszcze UI półki ani uploadu z KOReadera — to etap 2.
- Postęp można już synchronizować **istniejącym pluginem kosync**: w KOReaderze ustaw
  *Custom sync server* na `http://192.168.69.11:8099/` i zaloguj się na konto.
- Serwer działa po HTTP w LAN. HTTPS przez NPM/Caddy i dostęp z zewnątrz — kolejny krok.
- Backup: kopia `/srv/koreader-server/data`.

### Etap 2 — plugin v1 (2026-10-20) 🚧

**Kod:** `plugins/shelfsync.koplugin/` w `michalkulik/koreader`, commit `d43668bd7`.

Pliki:
- `client.lua` — klient HTTP/JSON + streaming upload/download (LuaSocket/ltn12),
- `index.lua` — trwały indeks ścieżka lokalna ↔ `book_id` + `last_rev`,
- `queue.lua` — kolejka offline uploadów i postępów (max 5 prób),
- `main.lua` — menu, logowanie tokenem, hooki czytnika, półka,
- `_meta.lua` — metadane wtyczki.

Zaimplementowane:
- logowanie do serwera przez `POST /api/v1/auth/token` (token + `device_id`,
  hasło nie jest zapisywane),
- menu **Shelf sync**: Półka, Synchronizuj teraz, Wyślij bieżącą książkę,
  Kolejka, Ustawienia,
- pull postępu przy otwarciu książki (`onReaderReady`) i push przy
  `onPageUpdate` (co 10 stron), `onCloseDocument`, `onSuspend`,
- automatyczny upload otwieranej książki (kolejka + `PUT /file`),
- półka z listą książek z serwera: pobranie do wybranego katalogu i otwarcie,
- ustawienia: adres serwera, login/logout, nazwa urządzenia, katalog pobierania,
  auto-upload, auto-progress,
- off-line: postęp i upload trafiają do kolejki, wznawiane po sieci / ręcznie.

**HTTPS:** `https://shelf.mkulik.eu` (NPM → `192.168.69.11:8099`) zweryfikowany:
`POST /api/v1/auth/token` i `GET /api/v1/books` → 200.

**Wydanie testowe:** [`v2026.11`](https://github.com/michalkulik/koreader/releases/tag/v2026.11)
— APK arm64 z wtyczką, podpisany tym samym kluczem (`SHA-256`
`1b2ad7d013a4835ceff13d1e0b9482485c9ac766b01d1335c1756d2c4a0b1679`).
Sprawdzone: plugin `shelfsync.koplugin` jest w `assets/module/koreader.7z`.

**Poprawka v2026.12:** [`v2026.12`](https://github.com/michalkulik/koreader/releases/tag/v2026.12)
— `shelfsync` dopisany do `BUILTIN_PLUGINS` (wcześniej mógł być pomijany jako
plugin zewnętrzny), log inicjalizacji. `SHA-256` APK:
`8d4e944704ace4ac816506149501951fb54894ca4c069a60346c98319908b37f`.
Wpis w menu: **Narzędzia → Shelf sync**.

**Poprawka v2026.13:** [`v2026.13`](https://github.com/michalkulik/koreader/releases/tag/v2026.13)
— właściwa przyczyna braku wpisu: KOReader wywołuje `addToMainMenu()` tylko dla
widgetów zarejestrowanych przez `menu:registerToMainMenu(self)`. Wtyczka ładowała
się, ale nie rejestrowała się w menu. Dodane w `ShelfSync:init()`. `SHA-256` APK:
`4845b5cf76b33d4082458c8bdc281323473de391dea5cf189cb8ac4b6fc8cd14`.
Zweryfikowane na KOReader Linux (`v2026.07.1`): `addToMainMenu` jest wołane,
a `menu_items.shelfsync` istnieje w menedżerze plików.

### Etap 3 — UI półki i OTA (2026-10-20) ✅

**Kod:** `plugins/shelfsync.koplugin/main.lua`, `frontend/ui/otamanager.lua`,
`tools/make-ota-assets.py`, `tools/release-android.sh`.

**UI półki:**
- nagłówek z ostatnim udanym sync-em i statusem offline,
- pozycja **⟳ Synchronize now** z liczbą oczekujących zmian i błędów,
- **Pending changes** otwierające kolejkę (ponowienie, liczba prób),
- **Continue reading** — książka z najświeższym postępem 0–100%,
- sortowanie półki: ostatnio czytane / tytuł / autor / ostatnio dodane
  (zapisywane w ustawieniach),
- long-press na książce: otwórz/pobierz, wyślij na półkę, usuń kopię lokalną,
  szczegóły,
- półka działa offline z trwałego cache (`library_cache` w settings),
- raport po ręcznym syncu: uploady, postęp, liczba książek, oczekujące, błędy,
- akcje Dispatcher: `shelfsync_sync`, `shelfsync_push_progress`,
  `shelfsync_pull_progress` (do gestów).

**OTA:**
- `ota_servers` wskazuje wyłącznie na wydania forka; stare wpisy upstream są
  migrowane w `getOTAServer()`,
- obsługa przekierowań 30x przy pobieraniu manifestu,
- manifest może zawierać nazwę pliku albo pełny URL,
- `tools/make-ota-assets.py` generuje manifest i `latest.json`,
- `tools/release-android.sh` publikuje APK + oba pliki OTA w wydaniu GitHub,
- menu: **Update → Settings → Source: github.com/michalkulik/koreader**.

**Testy:** wtyczka ładowana na KOReader Linux w trybie headless; `showShelf`,
`showBookActions`, `showBookDetails` i `showQueue` budują się bez błędów na
przykładowej bibliotece (log `DIAG shelf …`). Logika przekierowań OTA
przetestowana lokalnym serwerem 302 (przekierowanie względne, bezwzględne i 404).
`OTAManager:checkUpdate()` na żywym GitHubie zwrócił
`version=202616000000`, `link=…/releases/latest/download/koreader-android-arm64-v2026.16.apk`.

**Wydanie:** [`v2026.16`](https://github.com/michalkulik/koreader/releases/tag/v2026.16)
— APK arm64 `30 260 879` B, SHA-256
`b93c18d97a60b26e4f31eb97499ed35190a22ba0778a9385a5bc912e69bdc7c1`,
podpisany tym samym kluczem. Do wydania dołączone są manifest OTA i `latest.json`.
`v2026.14` było pierwszym wydaniem z OTA, `v2026.15` poprawia wyświetlanie czasu
postępu (serwer zwraca milisekundy), a `v2026.16` naprawia uszkadzający się cache
półki: dekoder JSON reprezentuje `null` funkcją, a `LuaSettings` zapisywał ją do
pliku jako `function: 0x…`, przez co plik ustawień przestawał być poprawnym Lua
i po restarcie wtyczka traciła token. `sanitize_for_storage()` usuwa `null`,
funkcje i inne niebezpieczne wartości przed zapisem. Sprawdzone na żywym
serwerze: cache zawiera tylko dane, token zostaje, a po restarcie wtyczka jest
zalogowana i widzi książki offline.

**Ograniczenia etapu 3:**
- brak okładek na liście — serwerowy `GET /api/v1/books/{id}/cover` nadal
  zwraca 404; potrzebne wyciąganie okładki z EPUB/PDF i miniatur w kliencie,
- transfery plików nadal synchroniczne (LuaSocket),
- brak wyszukiwania na półce,
- brak potwierdzenia `sha256` z `latest.json` przy aktualizacji,
- brak synchronizacji ustawień i kolekcji (etapy 4–5),
- wtyczka nie była jeszcze testowana na fizycznym Kindle 10.

**Następny krok:** zainstalować `v2026.16` na Androidzie i Kindle 10,
sprawdzić wbudowane **Update** (powinno pobrać wydanie z forka), potem etap 4
(synchronizacja ustawień) albo okładki półki.

