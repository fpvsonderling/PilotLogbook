/**
 * Pilot Logbook backend: a Google Apps Script project that keeps all data in
 * one Google Sheets spreadsheet. It can live inside the spreadsheet
 * (Extensions > Apps Script) or stand alone at script.google.com.
 *
 * - One tab per table, row 1 = column names, every cell stored as text.
 * - The app sends one POST per sync: its changed rows, and for each table the
 *   last server_seq it has seen. The script writes the rows (newer
 *   updated_at wins) and answers with every row changed since.
 * - monthlyBackup() copies the spreadsheet to a Drive folder on the 1st.
 *
 * Setup: run setup(), then Deploy > New deployment > Web app (execute as
 * "Me", access "Anyone"), then run connectionLink(). See README.md.
 */

// SCHEMA-START (kept equal to app/lib/data/schema.dart by a test)
const SCHEMA = {
  people: ['name', 'roles', 'email', 'active'],
  projects: ['name', 'active'],
  aircraft: ['name', 'model', 'serial', 'active'],
  batteries: ['name', 'set_name', 'serial', 'active'],
  mission_types: ['name', 'active'],
  flights: ['date', 'kind', 'project_id', 'aircraft_id', 'battery_id', 'takeoff_at', 'landing_at', 'duration_s', 'battery_pct', 'used', 'temp_c', 'mission', 'rp_id', 'pa_id', 'spotter_id', 'notes'],
  checklist_templates: ['name', 'kind', 'active'],
  checklist_items: ['template_id', 'position', 'label'],
  checks: ['template_id', 'aircraft_id', 'performed_at', 'performed_by_id', 'notes'],
  check_answers: ['check_id', 'item_id', 'result', 'comment'],
  faults: ['reported_at', 'aircraft_id', 'battery_id', 'equipment', 'severity', 'description', 'discovered_by_id', 'status', 'repair_started_at', 'technicians', 'work_performed', 'materials_used', 'final_note', 'signatory_id', 'signed_at'],
  fault_photos: ['fault_id', 'drive_file_id', 'url'],
  torque_specs: ['model', 'component', 'value_nm', 'notes'],
  documents: ['title', 'url', 'notes'],
};
// SCHEMA-END

const SYSTEM_COLUMNS = ['id', 'updated_at', 'server_seq', 'deleted'];
const BACKUP_FOLDER = 'PilotLogbook Backups';
const PHOTO_FOLDER = 'PilotLogbook Photos';

// ------------------------------------------------------------------ setup

/**
 * Step 1 of setup. Creates the spreadsheet (when this script is not inside
 * one), all tabs and columns, the access token and the monthly backup.
 * Safe to rerun.
 */
function setup() {
  const props = PropertiesService.getScriptProperties();
  if (!SpreadsheetApp.getActive() && !props.getProperty('SPREADSHEET_ID')) {
    const created = SpreadsheetApp.create('Pilot Logbook');
    props.setProperty('SPREADSHEET_ID', created.getId());
  }
  Object.keys(SCHEMA).forEach(function (table) { ensureSheet_(table, true); });
  if (!props.getProperty('API_TOKEN')) {
    props.setProperty('API_TOKEN', Utilities.getUuid());
  }
  if (!props.getProperty('SEQ')) props.setProperty('SEQ', '0');
  installTriggers();
  Logger.log('Done. Spreadsheet: ' + spreadsheet_().getUrl());
  Logger.log('Next: Deploy > New deployment > Web app, then run connectionLink.');
}

/**
 * Step 2, after Deploy > New deployment > Web app: prints the one link to
 * paste into the app's Settings (web app URL with the access token).
 */
function connectionLink() {
  const url = ScriptApp.getService().getUrl();
  if (!url) {
    Logger.log('Not deployed yet: Deploy > New deployment > Web app, then run this again.');
    return null;
  }
  // Run from the editor, getUrl() gives the owner-only /dev URL; the app
  // needs the deployed /exec one, which has the same id.
  const link = url.replace(/\/dev$/, '/exec') + '?key=' +
    PropertiesService.getScriptProperties().getProperty('API_TOKEN');
  Logger.log('Paste this into the app (Settings > Connection link):');
  Logger.log(link);
  return link;
}

/** Monthly backup on the 1st at about 03:00 (the spreadsheet's time zone). */
function installTriggers() {
  ScriptApp.getProjectTriggers()
    .filter(function (t) { return t.getHandlerFunction() === 'monthlyBackup'; })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('monthlyBackup').timeBased().onMonthDay(1).atHour(3).create();
}

function ensureSheet_(table, formatAll) {
  const ss = spreadsheet_();
  const columns = SYSTEM_COLUMNS.concat(SCHEMA[table]);
  let sheet = ss.getSheetByName(table);
  if (!sheet) {
    sheet = ss.insertSheet(table);
    sheet.getRange(1, 1, 1, columns.length).setValues([columns]).setFontWeight('bold');
    sheet.setFrozenRows(1);
    formatAll = true;
  } else {
    const header = readHeader_(sheet);
    const missing = columns.filter(function (c) { return header.indexOf(c) < 0; });
    if (missing.length) {
      sheet.getRange(1, header.length + 1, 1, missing.length).setValues([missing]).setFontWeight('bold');
    }
  }
  // Plain text everywhere, so Sheets never turns "2026-10-28" or "0:03:30"
  // into its own date or number values.
  if (formatAll) {
    sheet.getRange(1, 1, sheet.getMaxRows(), sheet.getMaxColumns()).setNumberFormat('@');
  }
  return sheet;
}

/**
 * The spreadsheet this script is bound to. A standalone script (made at
 * script.google.com) uses the spreadsheet setup() created, or any id put in
 * the SPREADSHEET_ID script property.
 */
function spreadsheet_() {
  const active = SpreadsheetApp.getActive();
  if (active) return active;
  const id = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');
  if (!id) throw new Error('Run setup first');
  return SpreadsheetApp.openById(id);
}

function readHeader_(sheet) {
  const lastColumn = sheet.getLastColumn();
  if (lastColumn === 0) return [];
  return sheet.getRange(1, 1, 1, lastColumn).getValues()[0].map(String);
}

// ------------------------------------------------------------------- http

function doGet() {
  return json_({ ok: true, app: 'PilotLogbook' });
}

function doPost(e) {
  try {
    const req = JSON.parse(e.postData.contents);
    const token = PropertiesService.getScriptProperties().getProperty('API_TOKEN');
    if (!token || req.token !== token) return json_({ ok: false, error: 'Wrong access token' });
    if (req.action === 'sync') return json_(sync_(req));
    if (req.action === 'uploadPhoto') return json_(uploadPhoto_(req));
    return json_({ ok: false, error: 'Unknown action ' + req.action });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// ------------------------------------------------------------------- sync

function sync_(req) {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const props = PropertiesService.getScriptProperties();
    let seq = Number(props.getProperty('SEQ') || 0);
    const push = req.push || {};
    const since = req.since || {};
    const accepted = {};
    const pulled = {};
    const maxSeq = {};

    Object.keys(SCHEMA).forEach(function (table) {
      const incoming = push[table] || [];
      if (!incoming.length && !(table in since)) return;
      const sheet = ensureSheet_(table, false);
      const header = readHeader_(sheet);
      const col = {};
      header.forEach(function (name, i) { col[name] = i; });
      const lastRow = sheet.getLastRow();
      const values = lastRow > 1
        ? sheet.getRange(2, 1, lastRow - 1, header.length).getValues()
        : [];
      const rowById = {};
      values.forEach(function (r, i) { rowById[String(r[col.id])] = i; });

      const changed = {};
      const rejected = [];
      accepted[table] = [];
      incoming.forEach(function (row) {
        if (!row.id) return;
        const at = rowById[row.id];
        if (at !== undefined && text_(values[at][col.updated_at]) > String(row.updated_at)) {
          rejected.push(at);
          return;
        }
        seq += 1;
        const out = header.map(function (name) {
          if (name === 'server_seq') return String(seq);
          if (name in row) return text_(row[name]);
          return at !== undefined ? values[at][col[name]] : '';
        });
        if (at !== undefined) {
          values[at] = out;
          changed[at] = true;
        } else {
          rowById[row.id] = values.length;
          values.push(out);
          changed[values.length - 1] = true;
        }
        accepted[table].push({ id: row.id, updated_at: row.updated_at, server_seq: seq });
      });

      writeChanged_(sheet, values, changed, lastRow - 1);

      // Rows the device has not seen yet, plus rows that beat its upload.
      const from = Number(since[table] || 0);
      let max = from;
      const rows = [];
      values.forEach(function (r, i) {
        const s = Number(r[col.server_seq] || 0);
        if (s > max) max = s;
        if (s > from || rejected.indexOf(i) >= 0) rows.push(toObject_(header, r));
      });
      pulled[table] = rows;
      maxSeq[table] = max;
    });

    props.setProperty('SEQ', String(seq));
    return { ok: true, accepted: accepted, pulled: pulled, seq: maxSeq };
  } finally {
    lock.releaseLock();
  }
}

/** Writes changed rows back in contiguous blocks, to keep API calls few. */
function writeChanged_(sheet, values, changed, existingCount) {
  const indexes = Object.keys(changed).map(Number).sort(function (a, b) { return a - b; });
  let start = 0;
  while (start < indexes.length) {
    let end = start;
    while (end + 1 < indexes.length && indexes[end + 1] === indexes[end] + 1) end++;
    const first = indexes[start];
    const block = values.slice(first, indexes[end] + 1);
    const range = sheet.getRange(first + 2, 1, block.length, block[0].length);
    if (first + block.length > existingCount) range.setNumberFormat('@');
    range.setValues(block);
    start = end + 1;
  }
}

function toObject_(header, r) {
  const o = {};
  header.forEach(function (name, i) { o[name] = text_(r[i]); });
  return o;
}

/** Cells typed by hand may hold real dates or numbers; send text back. */
function text_(v) {
  if (v === null || v === undefined) return '';
  if (v instanceof Date) {
    return Utilities.formatDate(v, Session.getScriptTimeZone(), "yyyy-MM-dd'T'HH:mm:ss");
  }
  return String(v);
}

// ----------------------------------------------------------------- photos

/** Saves a base64 photo to Drive and returns its id and link. */
function uploadPhoto_(req) {
  const folder = folder_(PHOTO_FOLDER);
  const blob = Utilities.newBlob(Utilities.base64Decode(req.data), req.mimeType || 'image/jpeg', req.name);
  const file = folder.createFile(blob);
  return { ok: true, drive_file_id: file.getId(), url: file.getUrl() };
}

// ----------------------------------------------------------------- backup

/** Copies the whole spreadsheet into the backup folder, one copy a month. */
function monthlyBackup() {
  const ss = spreadsheet_();
  const stamp = Utilities.formatDate(new Date(), Session.getScriptTimeZone(), 'yyyy-MM');
  DriveApp.getFileById(ss.getId()).makeCopy(ss.getName() + ' backup ' + stamp, folder_(BACKUP_FOLDER));
}

function folder_(name) {
  const it = DriveApp.getFoldersByName(name);
  return it.hasNext() ? it.next() : DriveApp.createFolder(name);
}
