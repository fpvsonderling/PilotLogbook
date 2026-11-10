# Pilot Logbook

A drone flight logbook for a company: flights, checklists, fault reports, maintenance, documents and pilot statistics, shared by every pilot in the organization. The app works offline and syncs with Firebase whenever a connection is available.

- `app/` is the Flutter app for Windows, Android, iOS and macOS.
- `firebase/` holds the Firestore and Storage security rules and their emulator tests.
- `apps_script/` is the Google Apps Script that moved the data from Google Sheets to Firebase. It now keeps the spreadsheet as a read-only daily copy of Firebase and makes a monthly backup.

## How it works

```
App (local SQLite database, works offline)
  ├─► Firebase Auth: each access key is an account (email + password packed into the key)
  ├─► Cloud Firestore: flights, people, aircraft, ... + meta/changes, members
  └─► Cloud Storage: fault photos (photos/<id>.jpg) and documents (documents/<folder>/<file>)

Apps Script, once a day: copies Firestore back into the Google Sheets tabs (read-only copy)
Apps Script, on the 1st of each month: copies the spreadsheet to Drive › PilotLogbook Backups
```

- Every database table is a Firestore collection, and every row is a document with the same `id`. The app talks to Firebase over REST, without the Firebase SDK.
- Every row has `id`, `updated_at`, `deleted` and `created_by`. When the same record was edited on two devices, the later edit wins. Deleted rows are not erased; they get `deleted = 1`.
- `meta/changes` keeps the time of the last change of each table, so a sync with nothing new reads a single document.
- Sync runs at start-up, after every save and from the **Sync** button at the top. The number on the button shows how many changes are not sent yet.

## Modules

- **Cargo LogBook** and **Inspection LogBook**: flights, both stored in the `flights` collection, told apart by `kind` (`cargo` / `inspection`). Each logbook offers only the drones marked for it (**Reference data → Drones → Used for**), and a cargo flight offers only the batteries of the chosen drone.
- **Daily checks**: the pilot picks themselves and a drone, and the app shows that drone's checklist (UA + GCS for FB3 per the FB3 Flight Manual v2.5.0, a short list for M30T). Each section is **OK**, **Problem** or **N/A**, and problems from the last three checks of the drone are shown at the top. Checklist items are in `app/lib/data/checklists.dart`.
- **Fault Repair**: report, repair and sign-off of a fault, with photos.
- **Maintenance**: per drone and per assembly (Arm, Center Plate, Propulsion, Load, Legs, Power System per battery set, FTS), with the flights and flight hours since the last service and due dates.
- **Projects** and **Competencies**: projects, and each person's competencies with expiry dates. The top bar warns when maintenance is due or a competency is expired or running out.
- **Statistic**: per pilot, with filters and PDF export.
- **Reference data**: people (roles pilot / spotter / technician / signatory / admin / viewer), projects, drones, batteries and task types. Changes reach everyone after a sync.
- **Nm**: bolt torque values to look up.
- **Documents**: manuals, procedures and certificates. Everyone can open them, only admins add, change or delete them. Each device keeps a copy, so documents open offline.

## Installing the app

Every version is on the [Releases](https://github.com/fpvsonderling/PilotLogbook/releases/latest) page. The app checks for a new version by itself and offers to install it.

- **Windows:** download `PilotLogbook-windows-<version>.zip`, unzip it and run `PilotLogbook\pilot_logbook.exe`. Windows SmartScreen may warn because the app is not signed: **More info → Run anyway**.
- **Android:** on the phone, download `PilotLogbook-android-<version>.apk` (or the always-latest [PilotLogbook.apk](https://github.com/fpvsonderling/PilotLogbook/releases/download/android-latest/PilotLogbook.apk)) and open it. Allow installing from this source, then **Install**. If Play Protect appears, choose **Install anyway**.
- **macOS:** download `PilotLogbook-macos-<version>.zip`, unzip it and drag **Pilot Logbook** to Applications. The first time: right-click → **Open** → **Open**.
- **iPhone / iPad:** install the new version from TestFlight.

Then open **Settings → Access key**, paste your key and press **Save and sync**.

A new version installs over the old one and keeps the data on the device. CI signs every Android build with the same key, stored in the Actions cache. GitHub removes a cache unused for 7 days; to keep the key permanently, add the repository secrets `ANDROID_KEYSTORE_BASE64` (a keystore with alias `pilotlogbook`, base64-encoded) and `ANDROID_KEYSTORE_PASSWORD`. If the key ever changes, press **Sync**, uninstall the old app and install the new one.

## Access keys and permissions

Every user signs in with an access key `PL2-…`. The rules in `firebase/firestore.rules` and `firebase/storage.rules` check every change, so even a modified app cannot change someone else's row.

- **Master admin key**: changes and deletes everything. Only for the owner.
- **Personal key**: an admin makes it in **Reference data → People →** person **→ Personal access key** and sends it to that person, who pastes it in **Settings → Access key**. What it allows depends on the person's roles in People:
  - regular roles (pilot, spotter, ...): add records, and change or delete only their own;
  - **admin**: change and delete everything, make keys for others;
  - **viewer (read only)**: see everything, add or change nothing (the add buttons are hidden).
- A personal key works only while the person is **Active** in People. Untick Active or delete the person, and the key stops working at once. **New key** makes a new key and turns the old one off (lost phone, key sent to the wrong person).
- **Shared pilots' key**: can only add records. To turn it off, set `active` to `false` on its document in the `members` collection in the Firebase console.
- The bottom of **Settings** shows what access this device has.

`members/{uid}` records whose key each account is: `kind` (`master` / `shared` / `person`), `person_id` and `active`.

Keep keys private: anyone with a key can reach the data.

## Google Sheets (read-only backup)

Before November 2026 the backend was a Google Sheets spreadsheet with an Apps Script web app. `moveToFirebase` in `apps_script/Code.gs` moved all data and files to Firebase and gave every app its new `PL2-…` key on its next sync. Since then the spreadsheet no longer accepts changes:

- `mirrorFromFirebase` copies every Firestore collection back into its tab once a day (trigger made by `installFirebaseTriggers`).
- `monthlyBackup` saves a copy of the spreadsheet to the Drive folder **PilotLogbook Backups** on the 1st of each month.

When you change `Code.gs`, redeploy it in Apps Script with **Deploy → Manage deployments →** the active deployment **→ Edit → Version: New version → Deploy**, so the URL stays the same.

## Development

```bash
cd app
flutter pub get
flutter analyze
flutter test
flutter run -d windows

# Apps Script tests (from the repository root)
node --test 'apps_script/test/*.test.js'

# Firestore / Storage rules and sync tests on the Firebase emulators (needs Node and Java)
cd firebase
npm ci
npm test
```

Table columns are defined in `app/lib/data/schema.dart`, and the same list is in `SCHEMA` in `apps_script/Code.gs`; `schema_test.dart` checks that they match. The rules in `firebase/` are copied into `Code.gs` as well, and a test keeps them equal.

Releases: **Actions → CI → Run workflow** with a version such as `v1.9.0` builds Windows, Android and macOS, publishes a GitHub release and uploads the iOS build to TestFlight.
