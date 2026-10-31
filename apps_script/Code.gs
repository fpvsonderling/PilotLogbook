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
 * - Links: the admin link can change and delete every row. A person's own
 *   link (the admin makes it in the app, People > person) can change and
 *   delete the rows that person added. The shared pilots' link only adds.
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
  flights: ['date', 'kind', 'project_id', 'aircraft_id', 'battery_id', 'takeoff_at', 'landing_at', 'duration_s', 'battery_pct', 'used', 'temp_c', 'mission', 'rp_id', 'pa_id', 'spotter_id', 'notes', 'aborted', 'near_miss'],
  checklist_templates: ['name', 'kind', 'active'],
  checklist_items: ['template_id', 'position', 'label'],
  checks: ['template_id', 'aircraft_id', 'performed_at', 'performed_by_id', 'notes'],
  check_answers: ['check_id', 'item_id', 'result', 'comment'],
  daily_checks_fb3: ['checked_at', 'aircraft_id', 'pilot_id', 'motors_propellers', 'centre_plate', 'load_structure', 'landing_gear', 'cargo_compartment', 'external_rf', 'power_on_gcs', 'ua_power_on', 'rfd_rclh', 'fts_rc_video', 'switch_off', 'storage', 'notes'],
  daily_checks_m30t: ['checked_at', 'aircraft_id', 'pilot_id', 'body_arms', 'propellers_motors', 'gimbal_camera', 'batteries', 'rc_plus', 'before_takeoff', 'notes'],
  faults: ['reported_at', 'aircraft_id', 'battery_id', 'equipment', 'severity', 'description', 'discovered_by_id'],
  fault_repairs: ['fault_id', 'started_at', 'finished_at', 'technicians', 'work_performed', 'materials_used', 'notes'],
  fault_signoffs: ['fault_id', 'tested_at', 'result', 'notes', 'signatory_id'],
  fault_photos: ['fault_id', 'repair_id', 'drive_file_id', 'url'],
  torque_specs: ['model', 'component', 'value_nm', 'notes'],
  documents: ['title', 'url', 'notes'],
};
// SCHEMA-END

const SYSTEM_COLUMNS = ['id', 'updated_at', 'server_seq', 'deleted', 'created_by'];
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
  adminToken_();
  if (!props.getProperty('SEQ')) props.setProperty('SEQ', '0');
  installTriggers();
  Logger.log('Done. Spreadsheet: ' + spreadsheet_().getUrl());
  Logger.log('Next: Deploy > New deployment > Web app, then run connectionLink.');
}

/**
 * Step 2, after Deploy > New deployment > Web app: prints the links to paste
 * into the app's Settings (web app URL with the access token). Pilots get
 * the first one; only administrators get the admin link.
 */
function connectionLink() {
  const url = ScriptApp.getService().getUrl();
  if (!url) {
    Logger.log('Not deployed yet: Deploy > New deployment > Web app, then run this again.');
    return null;
  }
  // Run from the editor, getUrl() gives the owner-only /dev URL; the app
  // needs the deployed /exec one, which has the same id.
  const base = url.replace(/\/dev$/, '/exec') + '?key=';
  const link = base + PropertiesService.getScriptProperties().getProperty('API_TOKEN');
  Logger.log('Link for pilots (Settings > Connection link):');
  Logger.log(link);
  Logger.log('Link for administrators only (can change and delete data):');
  Logger.log(base + adminToken_());
  return link;
}

/** The admin link's token, made on first use (also for older setups). */
function adminToken_() {
  const props = PropertiesService.getScriptProperties();
  let token = props.getProperty('ADMIN_TOKEN');
  if (!token) {
    token = Utilities.getUuid();
    props.setProperty('ADMIN_TOKEN', token);
  }
  return token;
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
    const user = user_(req.token);
    if (!user) return json_({ ok: false, error: 'Wrong access token' });
    if (req.action === 'sync') return json_(sync_(req, user));
    if (req.action === 'personLink') {
      if (!user.admin) return json_({ ok: false, error: 'Only the admin link can make links' });
      return json_({ ok: true, token: personToken_(String(req.person_id || '')) });
    }
    if (req.action === 'uploadPhoto') return json_(uploadPhoto_(req));
    if (req.action === 'photo') return json_(photo_(String(req.drive_file_id || '')));
    return json_({ ok: false, error: 'Unknown action ' + req.action });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

/**
 * Who a token belongs to: { admin, me } where me is a people id for a
 * person's own link, '' otherwise; null for an unknown token.
 */
function user_(token) {
  const props = PropertiesService.getScriptProperties();
  if (!token) return null;
  if (token === props.getProperty('ADMIN_TOKEN')) return { admin: true, me: '' };
  if (token === props.getProperty('API_TOKEN')) return { admin: false, me: '' };
  const me = personTokens_()[token];
  return me ? { admin: false, me: me } : null;
}

/** Personal tokens as token -> people id, in the PERSON_TOKENS property. */
function personTokens_() {
  return JSON.parse(PropertiesService.getScriptProperties().getProperty('PERSON_TOKENS') || '{}');
}

/** The token of a person's own link, made on first use. */
function personToken_(personId) {
  if (!personId) throw new Error('No person');
  const tokens = personTokens_();
  const existing = Object.keys(tokens).filter(function (t) { return tokens[t] === personId; })[0];
  if (existing) return existing;
  const token = Utilities.getUuid();
  tokens[token] = personId;
  PropertiesService.getScriptProperties().setProperty('PERSON_TOKENS', JSON.stringify(tokens));
  return token;
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// ------------------------------------------------------------------- sync

/**
 * [user] is { admin, me } from user_(). The admin changes anything. Others
 * change and delete only rows whose created_by is their own people id;
 * other edits are listed in `denied` and the row is sent back as it is, so
 * the device drops the edit. Sending the same version again (a retry after
 * a lost answer) is fine. created_by of a new row is set here, from the
 * link, not taken from the device.
 */
function sync_(req, user) {
  const admin = user.admin;
  const me = user.me;
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
    const denied = {};

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
      denied[table] = [];
      incoming.forEach(function (row) {
        if (!row.id) return;
        const at = rowById[row.id];
        const own = at !== undefined && !!me && text_(values[at][col.created_by]) === me;
        if (!admin && (at !== undefined
          ? text_(values[at][col.updated_at]) !== String(row.updated_at) && !own
          : String(row.deleted) === '1')) {
          if (at !== undefined) rejected.push(at);
          denied[table].push(row.id);
          return;
        }
        if (at !== undefined && text_(values[at][col.updated_at]) > String(row.updated_at)) {
          rejected.push(at);
          return;
        }
        seq += 1;
        const out = header.map(function (name) {
          if (name === 'server_seq') return String(seq);
          if (name === 'created_by') {
            if (at !== undefined) return values[at][col.created_by];
            return admin ? text_(row.created_by) : me;
          }
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
    return { ok: true, admin: !!admin, me: me, accepted: accepted, denied: denied, pulled: pulled, seq: maxSeq };
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

// ------------------------------------------------- old daily checks import

const OLD_UA_CHECKS = '1Ka2AUNiKkOdYfyfxFSIuDck5ApH_onn7pZ4Mmmvyew0';
const OLD_GCS_CHECKS = '1Z2oNDvp5NEIgCE3jyhkCOgUz5AvZrpJ0HAtahKq6UO0';

// Old Google Form columns, in order after Timestamp and drone number.
const OLD_UA_COLUMNS = ['motors_propellers', 'centre_plate', 'load_structure', 'landing_gear', 'cargo_compartment'];
const OLD_GCS_COLUMNS = ['ground_control_station', 'power_on_gcs', 'ua_power_on', 'rfd_rclh', 'fts_rc_video', 'switch_off', 'storage'];

/**
 * Run once from the editor: copies the old Google Form daily checks (UA and
 * GCS responses) into daily_checks_fb3. A UA and a GCS answer for the same
 * drone on the same day become one check. The old sheets are only read.
 * Safe to rerun: rows keep the same ids and are overwritten, unless they
 * were edited in the app since.
 */
function importOldDailyChecks() {
  const ua = readOldChecks_(OLD_UA_CHECKS, OLD_UA_COLUMNS);
  const gcs = readOldChecks_(OLD_GCS_CHECKS, OLD_GCS_COLUMNS);
  const out = buildImportedChecks_(ua, gcs, aircraftIds_());
  const res = sync_({ push: { aircraft: out.aircraft, daily_checks_fb3: out.checks }, since: {} }, { admin: true, me: '' });
  Logger.log('Imported ' + res.accepted.daily_checks_fb3.length + ' daily checks (' +
    ua.length + ' UA and ' + gcs.length + ' GCS answers), ' + out.aircraft.length + ' new drones.');
  return res.accepted.daily_checks_fb3.length;
}

function readOldChecks_(spreadsheetId, columns) {
  const sheet = SpreadsheetApp.openById(spreadsheetId).getSheets()[0];
  const rows = sheet.getDataRange().getDisplayValues().slice(1);
  return rows.filter(function (r) { return String(r[0]).trim(); }).map(function (r) {
    const o = { at: oldTimestamp_(r[0]), drone: String(r[1]).trim() };
    columns.forEach(function (c, i) { o[c] = String(r[i + 2] === undefined ? '' : r[i + 2]).trim(); });
    return o;
  }).filter(function (o) { return o.at && o.drone; });
}

/** "14/03/2026 18:23:08" -> "2026-03-14 18:23:08" */
function oldTimestamp_(v) {
  const m = String(v).trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?/);
  if (!m) return '';
  const p = function (n) { return ('0' + n).slice(-2); };
  return m[3] + '-' + p(m[2]) + '-' + p(m[1]) + ' ' + p(m[4]) + ':' + m[5] + ':' + (m[6] || '00');
}

/** Old free-text answers to the app's values: "Ok", "Not used" or the note. */
function oldValue_(v) {
  const t = String(v || '').trim();
  const k = t.toLowerCase().replace(/[.\s]+$/, '');
  if (k === '') return '';
  if (['ok', 'ook'].indexOf(k) >= 0) return 'Ok';
  if (['n/a', 'na', 'no', 'not applicable', 'not used', 'no cargo', 'no cg'].indexOf(k) >= 0) return 'Not used';
  return t;
}

function aircraftIds_() {
  const sheet = ensureSheet_('aircraft', false);
  const header = readHeader_(sheet);
  const ids = {};
  if (sheet.getLastRow() < 2) return ids;
  sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues().forEach(function (r) {
    if (String(r[header.indexOf('deleted')]) === '1') return;
    ids[String(r[header.indexOf('name')]).trim()] = String(r[header.indexOf('id')]);
  });
  return ids;
}

/** Pairs UA and GCS answers and turns them into daily_checks_fb3 rows. */
function buildImportedChecks_(ua, gcs, aircraftIds) {
  const updatedAt = '2026-10-29T00:00:00.000Z';
  const aircraft = [];
  const droneId = function (name) {
    if (!aircraftIds[name]) {
      aircraftIds[name] = 'import-aircraft-' + name;
      aircraft.push({ id: aircraftIds[name], updated_at: updatedAt, deleted: 0, name: name, active: 1 });
    }
    return aircraftIds[name];
  };
  const used = {};
  const checks = [];
  const add = function (u, g) {
    const first = u || g;
    const row = {
      id: 'import-' + first.drone + '-' + first.at.replace(/\D/g, ''),
      updated_at: updatedAt,
      deleted: 0,
      checked_at: first.at,
      aircraft_id: droneId(first.drone),
      pilot_id: '',
    };
    const notes = ['Imported from the old Google Form'];
    if (u) OLD_UA_COLUMNS.forEach(function (c) { row[c] = oldValue_(u[c]); });
    if (g) {
      OLD_GCS_COLUMNS.forEach(function (c) {
        if (c !== 'ground_control_station') row[c] = oldValue_(g[c]);
      });
      // The old form's first GCS question was the GCS in general, not only
      // External RF: keep Ok / Not used there, anything else as a note.
      const general = oldValue_(g.ground_control_station);
      if (general === 'Ok' || general === 'Not used' || general === '') {
        row.external_rf = general;
      } else {
        notes.push('GCS: ' + general);
      }
    }
    row.notes = notes.join('. ');
    checks.push(row);
  };
  ua.forEach(function (u) {
    const day = u.at.slice(0, 10);
    let best = -1;
    gcs.forEach(function (g, i) {
      if (used[i] || g.drone !== u.drone || g.at.slice(0, 10) !== day) return;
      if (best < 0 || Math.abs(timeOf_(g.at) - timeOf_(u.at)) < Math.abs(timeOf_(gcs[best].at) - timeOf_(u.at))) best = i;
    });
    if (best >= 0) used[best] = true;
    add(u, best >= 0 ? gcs[best] : null);
  });
  gcs.forEach(function (g, i) { if (!used[i]) add(null, g); });
  return { checks: checks, aircraft: aircraft };
}

/** Seconds since midnight of "yyyy-MM-dd HH:mm:ss". */
function timeOf_(at) {
  const t = at.slice(11).split(':').map(Number);
  return t[0] * 3600 + t[1] * 60 + t[2];
}

// ----------------------------------------------------------------- photos

/** Saves a base64 photo to Drive and returns its id and link. */
function uploadPhoto_(req) {
  const folder = folder_(PHOTO_FOLDER);
  const blob = Utilities.newBlob(Utilities.base64Decode(req.data), req.mimeType || 'image/jpeg', req.name);
  const file = folder.createFile(blob);
  return { ok: true, drive_file_id: file.getId(), url: file.getUrl() };
}

/**
 * A photo's bytes as base64, for the app to show and keep offline. Only
 * files listed in fault_photos, so a link cannot read other Drive files.
 */
function photo_(fileId) {
  if (!fileId || photoIds_().indexOf(fileId) < 0) return { ok: false, error: 'Unknown photo' };
  const blob = DriveApp.getFileById(fileId).getBlob();
  return { ok: true, mimeType: blob.getContentType(), data: Utilities.base64Encode(blob.getBytes()) };
}

function photoIds_() {
  const sheet = ensureSheet_('fault_photos', false);
  if (sheet.getLastRow() < 2) return [];
  const header = readHeader_(sheet);
  const col = header.indexOf('drive_file_id');
  return sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues()
    .map(function (r) { return String(r[col]); });
}

// ------------------------------------------------- old fault reports import

const OLD_FAULTS = '1JNJ2zhb0Hu0rzot8aZ_EL2UIXkxgfQsU2Tdo4VgzAIA';

/**
 * Run once from the editor: copies the old AppSheet "FB3 Fault Repair
 * Report" (tab MFR) into the new tabs, every fault with its repair,
 * sign-off and photos. The old sheet is only read. Safe to rerun. Another
 * spreadsheet or tab can be given: importOldFaults('1abc...', 'Sheet1').
 */
function importOldFaults(spreadsheetId, sheetName) {
  const ss = SpreadsheetApp.openById(spreadsheetId || OLD_FAULTS);
  const sheet = ss.getSheetByName(sheetName || 'MFR') || ss.getSheets()[0];
  const rows = sheet.getDataRange().getDisplayValues();
  const out = buildImportedFaults_(rows, aircraftIds_(), namedIds_('people'), findPhoto_);
  const res = sync_({ push: out, since: {} }, { admin: true, me: '' });
  Logger.log('Imported ' + res.accepted.faults.length + ' faults, ' +
    res.accepted.fault_repairs.length + ' repairs, ' + res.accepted.fault_signoffs.length +
    ' sign-offs, ' + res.accepted.fault_photos.length + ' photos (' + out.missingPhotos + ' photos not found on Drive).');
  return res.accepted.faults.length;
}

/** Old column names, matched by their start, ignoring case. */
const OLD_FAULT_COLUMNS = {
  at: 'timestamp',
  item: 'dron',
  severity: 'severity',
  description: 'description',
  photo: 'visual',
  discoveredBy: 'discovered',
  status: 'status',
  repairStart: 'repair start',
  technician: 'technician',
  work: 'work performed',
  materials: 'materials',
  torque: 'specific torque',
  verification: 'post-repair',
  functionalTest: 'functional test',
  finalNote: 'final note',
  signatory: 'authorized sign',
  signedAt: 'date',
};

/**
 * Old rows (header first) to rows for faults, fault_repairs, fault_signoffs
 * and fault_photos. [findPhoto] turns AppSheet's image path into a Drive
 * file ({ id, url }) or null.
 */
function buildImportedFaults_(rows, aircraftIds, peopleIds, findPhoto) {
  const updatedAt = '2026-10-31T00:00:00.000Z';
  const header = rows[0].map(function (h) { return String(h).trim().toLowerCase(); });
  const idx = {};
  Object.keys(OLD_FAULT_COLUMNS).forEach(function (k) {
    // "date" alone is the sign-off date; other names match by their start.
    idx[k] = header.findIndex(function (h) {
      return k === 'signedAt' ? h === 'date' || h.indexOf('authorized date') === 0 : h.indexOf(OLD_FAULT_COLUMNS[k]) === 0;
    });
  });
  const get = function (r, k) { return idx[k] < 0 ? '' : String(r[idx[k]] === undefined ? '' : r[idx[k]]).trim(); };
  const person = function (name) {
    return peopleIds[name.toLowerCase()] || name;
  };
  const sys = function (id) { return { id: id, updated_at: updatedAt, deleted: 0 }; };
  const out = { aircraft: [], faults: [], fault_repairs: [], fault_signoffs: [], fault_photos: [], missingPhotos: 0 };
  rows.slice(1).forEach(function (r) {
    const at = anyTimestamp_(get(r, 'at'));
    if (!at) return;
    const item = get(r, 'item');
    const id = 'import-fault-' + at.replace(/\D/g, '') + '-' + item.replace(/[^A-Za-z0-9]/g, '').slice(0, 24);
    // "24", "024", "Dron 18" or "Dron 24 bat 181 set 44 id3" (the rest
    // stays as equipment text).
    const drone = item.match(/^(?:dron[e]?\s*)?0*(\d{1,3})$/i) || item.match(/^dron[e]?\s*0*(\d{1,3})\b/i);
    let aircraftId = '';
    if (drone) {
      aircraftId = aircraftIds[drone[1]];
      if (!aircraftId) {
        aircraftId = aircraftIds[drone[1]] = 'import-aircraft-' + drone[1];
        out.aircraft.push(Object.assign(sys(aircraftId), { name: drone[1], active: 1 }));
      }
    }
    const severity = get(r, 'severity').match(/(\d)/);
    out.faults.push(Object.assign(sys(id), {
      reported_at: at,
      aircraft_id: aircraftId,
      battery_id: '',
      equipment: drone && drone[0] === item ? '' : item,
      severity: severity ? severity[1] : '',
      description: get(r, 'description'),
      discovered_by_id: person(get(r, 'discoveredBy')),
    }));
    get(r, 'photo').split(/\s*,\s*/).filter(String).forEach(function (path, i) {
      const file = findPhoto(path);
      if (!file) { out.missingPhotos++; return; }
      out.fault_photos.push(Object.assign(sys(id + '-photo-' + i), {
        fault_id: id, repair_id: '', drive_file_id: file.id, url: file.url,
      }));
    });
    const status = get(r, 'status').toLowerCase();
    const work = get(r, 'work');
    if (status.indexOf('repaired') === 0 || status.indexOf('fixed') === 0 || work) {
      out.fault_repairs.push(Object.assign(sys(id + '-repair'), {
        fault_id: id,
        started_at: anyTimestamp_(get(r, 'repairStart')),
        finished_at: '',
        technicians: get(r, 'technician'),
        work_performed: work,
        materials_used: get(r, 'materials'),
        notes: '',
      }));
    }
    if (status.indexOf('fixed') === 0) {
      out.fault_signoffs.push(Object.assign(sys(id + '-signoff'), {
        fault_id: id,
        tested_at: anyTimestamp_(get(r, 'signedAt')) || anyTimestamp_(get(r, 'repairStart')) || at,
        result: 'pass',
        notes: [
          ['Torque', get(r, 'torque')],
          ['Verification', get(r, 'verification')],
          ['Functional test', get(r, 'functionalTest')],
          ['', get(r, 'finalNote')],
        ].filter(function (n) { return n[1]; }).map(function (n) { return n[0] ? n[0] + ': ' + n[1] : n[1]; }).join('. '),
        signatory_id: person(get(r, 'signatory')),
      }));
    }
  });
  return out;
}

/**
 * AppSheet and Sheets dates to "yyyy-MM-dd HH:mm:ss": "8/15/2026 10:08:41 AM"
 * (month first when there is AM/PM), "15/08/2026 10:08:41" (day first) or
 * "2026-08-15 10:08:41".
 */
function anyTimestamp_(v) {
  const t = String(v || '').trim();
  const p = function (n) { return ('0' + n).slice(-2); };
  let m = t.match(/^(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?/);
  if (m) return m[1] + '-' + m[2] + '-' + m[3] + ' ' + p(m[4]) + ':' + m[5] + ':' + (m[6] || '00');
  m = t.match(/^(\d{1,2})[\/.](\d{1,2})[\/.](\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AP]M)?$/i);
  if (!m) return '';
  let h = Number(m[4]);
  let month = m[2];
  let day = m[1];
  if (m[7]) {
    month = m[1];
    day = m[2];
    if (m[7].toUpperCase() === 'PM' && h < 12) h += 12;
    if (m[7].toUpperCase() === 'AM' && h === 12) h = 0;
  }
  return m[3] + '-' + p(month) + '-' + p(day) + ' ' + p(h) + ':' + m[5] + ':' + (m[6] || '00');
}

/** Lower-case name -> id of a reference tab. */
function namedIds_(table) {
  const sheet = ensureSheet_(table, false);
  const header = readHeader_(sheet);
  const ids = {};
  if (sheet.getLastRow() < 2) return ids;
  sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues().forEach(function (r) {
    if (String(r[header.indexOf('deleted')]) === '1') return;
    ids[String(r[header.indexOf('name')]).trim().toLowerCase()] = String(r[header.indexOf('id')]);
  });
  return ids;
}

/** AppSheet keeps "Folder_Images/name.jpg"; the file is found by its name. */
function findPhoto_(path) {
  const name = String(path).split('/').pop();
  if (!name) return null;
  const it = DriveApp.getFilesByName(name);
  if (!it.hasNext()) return null;
  const file = it.next();
  return { id: file.getId(), url: file.getUrl() };
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

// ------------------------------------------------------- app builds on Drive

/*
 * A Drive folder that always holds the newest app builds. Every 15 minutes
 * syncReleases() asks GitHub for the latest release; when it is new, each
 * build is copied into the folder over the old file (same file, same link,
 * new name with the version), and the read-me is rewritten. Files bigger
 * than one Apps Script fetch (50 MB) are moved in 16 MB pieces.
 */
const APPS_FOLDER = 'PilotLogbook - aplikacja';
const APPS_README = 'CZYTAJ MNIE.txt';
const GITHUB_REPO = 'fpvsonderling/PilotLogbook';
const RELEASE_FILES = [
  { key: 'windows', asset: 'PilotLogbook-windows-{v}.zip', mime: 'application/zip' },
  { key: 'android', asset: 'PilotLogbook-android-{v}.apk', mime: 'application/vnd.android.package-archive' },
  { key: 'macos', asset: 'PilotLogbook-macos-{v}.zip', mime: 'application/zip' },
];
const CHUNK_BYTES = 16 * 1024 * 1024; // a multiple of 256 KB, as Drive wants

/**
 * Run once: makes the folder (anyone with the link can download), checks
 * for a new release every 15 minutes, copies the current one now and logs
 * the folder link.
 */
function setupAppsFolder() {
  const folder = appsFolder_();
  folder.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
  ScriptApp.getProjectTriggers()
    .filter(function (t) { return t.getHandlerFunction() === 'syncReleases'; })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('syncReleases').timeBased().everyMinutes(15).create();
  PropertiesService.getScriptProperties().deleteProperty('APPS_VERSION');
  syncReleases();
  Logger.log('Folder z aplikacją: ' + folder.getUrl());
  return folder.getUrl();
}

/** Copies the latest GitHub release into the folder when it is new. */
function syncReleases() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(1000)) return;
  try {
    const props = PropertiesService.getScriptProperties();
    const version = latestRelease_();
    if (!version || props.getProperty('APPS_VERSION') === version) return;
    const folder = appsFolder_();
    const ids = JSON.parse(props.getProperty('APPS_FILES') || '{}');
    const copied = {};
    RELEASE_FILES.forEach(function (f) {
      const name = f.asset.replace('{v}', version);
      const url = 'https://github.com/' + GITHUB_REPO + '/releases/download/' + version + '/' + name;
      if (!assetUrl_(url)) return; // this release has no such build
      ids[f.key] = copyToDrive_(url, name, f.mime, folder, ids[f.key]);
      props.setProperty('APPS_FILES', JSON.stringify(ids));
      copied[f.key] = name;
    });
    writeReadme_(folder, version, copied);
    props.setProperty('APPS_VERSION', version);
  } finally {
    lock.releaseLock();
  }
}

function appsFolder_() {
  const id = PropertiesService.getScriptProperties().getProperty('APPS_FOLDER_ID');
  if (id) {
    try {
      const folder = DriveApp.getFolderById(id);
      if (!folder.isTrashed()) return folder;
    } catch (e) { /* deleted: make a new one */ }
  }
  const folder = folder_(APPS_FOLDER);
  PropertiesService.getScriptProperties().setProperty('APPS_FOLDER_ID', folder.getId());
  return folder;
}

/** The tag of the latest release, read from github.com's redirect. */
function latestRelease_() {
  const res = UrlFetchApp.fetch('https://github.com/' + GITHUB_REPO + '/releases/latest',
    { followRedirects: false, muteHttpExceptions: true });
  const m = String(header_(res, 'location') || '').match(/\/releases\/tag\/([^\/?#]+)$/);
  return m ? decodeURIComponent(m[1]) : null;
}

/** Where a release file's bytes are now (a short-lived link), or null. */
function assetUrl_(url) {
  const res = UrlFetchApp.fetch(url, { followRedirects: false, muteHttpExceptions: true });
  return res.getResponseCode() === 302 ? header_(res, 'location') : null;
}

function header_(res, name) {
  const headers = res.getAllHeaders();
  const key = Object.keys(headers).filter(function (k) { return k.toLowerCase() === name; })[0];
  const v = key ? headers[key] : null;
  return Array.isArray(v) ? v[0] : v;
}

/**
 * Streams one release file into Drive with a resumable upload: over the
 * file we made last time when it still exists, so its link stays the same.
 * Returns the Drive file id.
 */
function copyToDrive_(url, name, mime, folder, fileId) {
  const first = UrlFetchApp.fetch(assetUrl_(url), { headers: { Range: 'bytes=0-0' }, muteHttpExceptions: true });
  const total = Number(String(header_(first, 'content-range') || '').split('/')[1]);
  if (first.getResponseCode() !== 206 || !total) throw new Error('No size for ' + name);

  let existing = false;
  if (fileId) {
    try { existing = !DriveApp.getFileById(fileId).isTrashed(); } catch (e) { existing = false; }
  }
  const auth = { Authorization: 'Bearer ' + ScriptApp.getOAuthToken() };
  const start = UrlFetchApp.fetch('https://www.googleapis.com/upload/drive/v3/files' +
    (existing ? '/' + fileId : '') + '?uploadType=resumable&fields=id', {
    method: existing ? 'patch' : 'post',
    contentType: 'application/json; charset=UTF-8',
    headers: Object.assign({ 'X-Upload-Content-Type': mime, 'X-Upload-Content-Length': String(total) }, auth),
    payload: JSON.stringify(existing ? { name: name } : { name: name, parents: [folder.getId()] }),
    muteHttpExceptions: true,
  });
  const session = header_(start, 'location');
  if (start.getResponseCode() !== 200 || !session) {
    throw new Error('Drive upload of ' + name + ' failed: ' + start.getContentText());
  }
  for (let from = 0; from < total; from += CHUNK_BYTES) {
    const to = Math.min(from + CHUNK_BYTES, total) - 1;
    const piece = UrlFetchApp.fetch(assetUrl_(url), { headers: { Range: 'bytes=' + from + '-' + to }, muteHttpExceptions: true });
    if (piece.getResponseCode() !== 206) throw new Error('Download of ' + name + ' failed: ' + piece.getResponseCode());
    const put = UrlFetchApp.fetch(session, {
      method: 'put',
      contentType: mime,
      headers: { 'Content-Range': 'bytes ' + from + '-' + to + '/' + total },
      payload: piece.getContent(),
      muteHttpExceptions: true,
    });
    const code = put.getResponseCode();
    if (code === 200 || code === 201) return JSON.parse(put.getContentText()).id;
    if (code !== 308) throw new Error('Drive upload of ' + name + ' failed: ' + put.getContentText());
  }
  throw new Error('Drive upload of ' + name + ' did not finish');
}

/** The read-me: what is in the folder and how to install it. */
function readmeText_(version, copied, testFlight) {
  const lines = ['Pilot Logbook ' + version, ''];
  if (copied.windows) lines.push('Windows: pobierz ' + copied.windows + ', rozpakuj i uruchom PilotLogbook\\pilot_logbook.exe.');
  if (copied.android) lines.push('Android: pobierz ' + copied.android + ' na telefonie i zainstaluj (zezwól na instalację z tego źródła).');
  lines.push('iPhone / iPad: zainstaluj TestFlight z App Store, potem ' +
    (testFlight ? 'otwórz ten link: ' + testFlight : 'poproś administratora o zaproszenie do TestFlight') +
    '. Nowe wersje przychodzą same przez TestFlight.');
  lines.push(copied.macos
    ? 'macOS: pobierz ' + copied.macos + ', rozpakuj i przenieś Pilot Logbook do Aplikacji.'
    : 'macOS: wersja na Maca jest w przygotowaniu.');
  lines.push('', 'Pliki w tym folderze podmieniają się same po każdym nowym wydaniu.');
  return lines.join('\n');
}

function writeReadme_(folder, version, copied) {
  const text = readmeText_(version, copied, PropertiesService.getScriptProperties().getProperty('TESTFLIGHT_LINK'));
  const it = folder.getFilesByName(APPS_README);
  if (it.hasNext()) it.next().setContent(text);
  else folder.createFile(APPS_README, text, MimeType.PLAIN_TEXT);
}
