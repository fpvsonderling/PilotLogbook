# Pilot Logbook

Drone flight logbook for a company: flights, checklists, fault reports and pilot statistics. The app works offline and syncs with a single Google Sheet whenever a connection is available.

- `app/` — the Flutter app (Windows first, then Android, iOS, macOS).
- `apps_script/` — the Google Sheets script: receives data from the app, stores photos on Google Drive and makes a monthly backup.

## How it works

```
App (local SQLite database, works offline)
        │  one HTTPS sync: push own changes, pull everyone else's
        ▼
Apps Script in the Google Sheet  ──►  tabs: flights, people, aircraft, ...
                                 ──►  Google Drive: PilotLogbook Photos, PilotLogbook Backups
```

- Each database table is its own sheet tab. The first row holds the column names; all values are stored as text.
- Every row has `id`, `updated_at`, `server_seq`, `deleted` and `created_by`. If the same record was edited on two devices, the later edit wins. Deleted rows are not erased; they get `deleted = 1`.
- Backup: on the 1st of every month at about 03:00 the script puts a copy of the whole spreadsheet into the **PilotLogbook Backups** folder on Google Drive.

## Setup (once, ~10 minutes)

1. Open [script.google.com](https://script.google.com) with the company Google account and click **New project**. If something doesn't open, use an incognito window (Ctrl+Shift+N) and sign in to one account only.
2. Open the [script code](https://raw.githubusercontent.com/fpvsonderling/PilotLogbook/main/apps_script/Code.gs), select all (Ctrl+A), copy (Ctrl+C) and paste it into the editor, replacing what is there. Save (Ctrl+S).
3. At the top, choose the **setup** function and click **Run**. Google will ask for permissions: **Review permissions** → your account → **Advanced** → **Go to the project** → **Allow**. The script creates the "Pilot Logbook" spreadsheet with all tabs and turns on the monthly backup.
4. Click **Deploy → New deployment**. Type (gear icon): **Web app**, "Execute as": **Me**, "Who has access": **Anyone**. Click **Deploy**.
5. Choose the **connectionLink** function and click **Run**. Two links like `https://script.google.com/macros/s/.../exec?key=...` appear in the log at the bottom: the first is for pilots, the second for administrators.
6. In the app open **Settings**, paste the link and click **Save and sync**.

There is one pilot link for everyone: each pilot pastes it into their own Settings. Give the admin link only to people who may edit and delete data.

## Who can change what

- **Administrator** (the second link from `connectionLink`): opens any record with a click and edits it; the window has **Delete**. In Reference data a deleted person or drone disappears from the pick lists, but their name stays in old flights.
- **Pilot with a personal link**: edits and deletes only the flights and daily checks they added themselves. The administrator creates the link: **Reference data → People →** person **→ Personal link**. The link is copied; send it to that person, who pastes it into their Settings instead of the shared one.
- **Shared pilot link**: can only add records; saved records don't open.
- The bottom of **Settings** shows what access this computer has.
- The script enforces this too: even a modified app cannot change someone else's row in the spreadsheet. Who added a row is stored in the `created_by` column.

## Installing the app on Windows

1. Open the latest release on the [Releases](https://github.com/fpvsonderling/PilotLogbook/releases) page and download `PilotLogbook-windows-<version>.zip` (or **Actions → CI →** latest successful run **→ Artifacts → `PilotLogbook-windows`**).
2. Unzip it into any folder and run `pilot_logbook.exe`. Windows may show a SmartScreen warning because the app is not signed yet: **More info → Run anyway**.
3. In the app open **Settings**, paste the link from setup step 5 and click **Save and sync**.
4. In **Reference data** fill in people (with roles pilot / spotter / technician / signatory), projects, drones, batteries and task types. Everyone gets them after a sync.

Sync runs at startup, after every save and with the **Sync** button at the top. The number on the button shows how many changes have not been sent yet.

## Installing the app on Android

1. On the phone open the [PilotLogbook.apk](https://github.com/fpvsonderling/PilotLogbook/releases/download/android-latest/PilotLogbook.apk) link (latest build). The APK is also attached to every release and available in **Actions → CI → Artifacts → `PilotLogbook-android`**.
2. Open the downloaded file. Android asks for permission to install apps from the browser: **Settings → Allow from this source**, then **Install**. If Play Protect appears, tap **Install anyway**.
3. Copy your connection link (for example from a message), open **☰ → Settings** in the app, tap the paste icon on the right of the field and then **Save and sync**.

A new version installs over the old one and the data on the phone is kept: CI signs every build with the same key, stored in the Actions cache. GitHub deletes caches unused for 7 days; to make the key permanent, add the repository secrets `ANDROID_KEYSTORE_BASE64` (a keystore with alias `pilotlogbook`, base64-encoded) and `ANDROID_KEYSTORE_PASSWORD`. If the key has changed, tap **Sync** before installing the new version, uninstall the old app and install the new one.

## Installing the app on iPhone

Every change on `main` is uploaded to TestFlight automatically. Install the **TestFlight** app from the App Store and accept the invitation for Pilot Logbook.

## Daily checks

In **Daily checks** the pilot picks themselves and the drone, and the app shows that drone's checklist. For FB3 (18, 19, 24) it is UA and GCS together per FB3 Flight Manual v2.5.0; M30T has its own short list. Each section has **OK** / **Problem** buttons (and **N/A** where a section may not be used). Problems from the drone's last three checks are shown at the top.

In the spreadsheet these are the `daily_checks_fb3` and `daily_checks_m30t` tabs: one row per check, one column per section with the value `Ok`, `Not used` or the problem text, as in the old AppSheet spreadsheet. The checklist items live in `app/lib/data/checklists.dart`.

## Security

The connection link contains an access key: anyone who has it can add data to the spreadsheet, so do not publish it. If a link leaks, delete the `API_TOKEN` property in **Project Settings → Script properties**, run `setup` again, then `connectionLink`, and hand out the new link. Do the same with the `ADMIN_TOKEN` property for the admin link. Personal links are stored in the `PERSON_TOKENS` property: delete it to disable all personal links.

## Development

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter run -d windows

# Apps Script tests (from the repository root)
node --test 'apps_script/test/*.test.js'
```

Table columns are defined in `app/lib/data/schema.dart`, and the same list is in `SCHEMA` in `apps_script/Code.gs`. The `schema_test.dart` test checks that they match: when you add a column, change both files and run `setup` again in the spreadsheet.
