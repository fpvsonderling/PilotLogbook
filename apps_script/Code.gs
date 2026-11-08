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
 * - Access keys: the app is given a short access key, never this script's
 *   address. The master admin key changes and deletes every row. A person's
 *   own key (the admin makes it in the app, People > person) works only
 *   while that person is active in People; it changes and deletes the rows
 *   that person added, every row when the person has the admin role, and
 *   nothing at all when the person has the viewer (read only) role. The
 *   shared pilots' key only adds; disableSharedKey() turns it off.
 *
 * Setup: run setup(), then Deploy > New deployment > Web app (execute as
 * "Me", access "Anyone"), then run connectionLink(). See README.md.
 */

// SCHEMA-START (kept equal to app/lib/data/schema.dart by a test)
const SCHEMA = {
  people: ['name', 'roles', 'email', 'active'],
  projects: ['name', 'active', 'client', 'country', 'coordinates', 'maps_url', 'zone_map_url', 'notes'],
  aircraft: ['name', 'model', 'serial', 'active', 'usage'],
  batteries: ['name', 'set_name', 'serial', 'active', 'aircraft_ids'],
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
  fault_photos: ['fault_id', 'repair_id', 'drive_file_id', 'url', 'storage_path'],
  maintenance: ['performed_at', 'aircraft_id', 'technician_id', 'arm_assembly', 'center_plate', 'propulsion_system', 'load_assembly', 'leg_assembly', 'power_system', 'fts', 'notes'],
  maintenance_intervals: ['model', 'section', 'hours', 'flights', 'days'],
  torque_specs: ['model', 'component', 'value_nm', 'notes'],
  competencies: ['person_id', 'type', 'number', 'issued_on', 'expires_on', 'url', 'notes', 'verified', 'verified_by'],
  documents: ['title', 'url', 'notes', 'drive_file_id', 'file_name', 'mime_type', 'size_bytes', 'file_version', 'storage_path'],
};
// SCHEMA-END

const SYSTEM_COLUMNS = ['id', 'updated_at', 'server_seq', 'deleted', 'created_by'];
const BACKUP_FOLDER = 'PilotLogbook Backups';
const PHOTO_FOLDER = 'PilotLogbook Photos';
const DOCUMENT_FOLDER = 'PilotLogbook Documents';
// Tables only the admin link may add to, change or delete.
const ADMIN_ONLY_TABLES = ['documents', 'maintenance_intervals', 'projects'];
// Tables of one person's own rows (column person_id): only that person
// (with their own key) and the admin get them, add, change and delete them;
// only the admin sets verified.
const PERSONAL_TABLES = ['competencies'];
// Documents go to the app in pieces of this many bytes, so big manuals fit
// in one answer each.
const DOCUMENT_PART = 8 * 1024 * 1024;

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
 * Step 2, after Deploy > New deployment > Web app: prints the access keys to
 * paste into the app's Settings > Access key. The master admin key is for
 * you only; everyone else gets a personal key made in the app (People >
 * person > Personal key). Returns the shared pilots' key, or the admin key
 * when the shared key is turned off.
 */
function connectionLink() {
  const url = webAppUrl_();
  if (!url) {
    Logger.log('Not deployed yet: Deploy > New deployment > Web app, then run this again.');
    return null;
  }
  const props = PropertiesService.getScriptProperties();
  const admin = accessKey_(url, adminToken_());
  Logger.log('Master admin key (only for you, can change and delete everything):');
  Logger.log(admin);
  if (props.getProperty('SHARED_KEY_OFF') === '1') {
    Logger.log('The shared pilots\' key is off: give each person their own key from the app.');
    return admin;
  }
  const shared = accessKey_(url, props.getProperty('API_TOKEN'));
  Logger.log('Shared pilots\' key (can only add; turn it off with disableSharedKey):');
  Logger.log(shared);
  return shared;
}

/**
 * Turns the shared pilots' key off, once everyone has a personal key: then
 * only people listed as active in People (and the master admin key) get in.
 */
function disableSharedKey() {
  PropertiesService.getScriptProperties().setProperty('SHARED_KEY_OFF', '1');
  Logger.log('Shared pilots\' key is off. enableSharedKey() turns it back on.');
}

function enableSharedKey() {
  PropertiesService.getScriptProperties().setProperty('SHARED_KEY_OFF', '0');
  Logger.log('Shared pilots\' key is on again.');
}

/** The deployed /exec URL (run from the editor, getUrl() gives /dev). */
function webAppUrl_() {
  const url = ScriptApp.getService().getUrl();
  return url ? url.replace(/\/dev$/, '/exec') : '';
}

/**
 * The access key the app is given: "PL1-" and, base64url, the web app id
 * (or the whole URL when it is not a plain script.google.com one), a space
 * and the token. Kept equal to accessKey in app/lib/data/sync/sync_service.dart.
 */
function accessKey_(url, token) {
  const m = /^https:\/\/script\.google\.com\/macros\/s\/([^/]+)\/exec$/.exec(url);
  const payload = (m ? m[1] : url) + ' ' + token;
  return 'PL1-' + Utilities.base64EncodeWebSafe(payload, Utilities.Charset.UTF_8).replace(/=+$/, '');
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

/**
 * Monthly backup on the 1st at about 03:00 (the spreadsheet's time zone),
 * and every hour a look for documents changed in Drive.
 */
function installTriggers() {
  ScriptApp.getProjectTriggers()
    .filter(function (t) {
      return ['monthlyBackup', 'refreshDocuments'].indexOf(t.getHandlerFunction()) >= 0;
    })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('monthlyBackup').timeBased().onMonthDay(1).atHour(3).create();
  ScriptApp.newTrigger('refreshDocuments').timeBased().everyHours(1).create();
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
  return json_({ ok: true });
}

function doPost(e) {
  try {
    const req = JSON.parse(e.postData.contents);
    const moved = movedAnswer_(req.token);
    if (moved) return json_(moved);
    const user = user_(req.token);
    if (!user) return json_({ ok: false, error: 'Access key not valid or turned off. Ask the administrator.' });
    if (req.action === 'sync') return json_(sync_(req, user));
    if (req.action === 'personLink') {
      if (!user.admin) return json_({ ok: false, error: 'Only an administrator can make access keys' });
      const token = personToken_(String(req.person_id || ''), req.renew === true);
      return json_({ ok: true, token: token, key: accessKey_(webAppUrl_(), token) });
    }
    if (req.action === 'uploadPhoto') {
      if (user.readOnly) return json_({ ok: false, error: 'Read only access' });
      return json_(uploadPhoto_(req));
    }
    if (req.action === 'photo') return json_(photo_(String(req.drive_file_id || '')));
    if (req.action === 'documentUpload' || req.action === 'documentInfo') {
      if (!user.admin) return json_({ ok: false, error: 'Only the admin can add documents' });
      if (req.action === 'documentUpload') return json_(documentUpload_(req));
      return json_(documentInfo_(String(req.drive_file_id || '')));
    }
    if (req.action === 'documentPart') return json_(documentPart_(req));
    return json_({ ok: false, error: 'Unknown action ' + req.action });
  } catch (err) {
    return json_({ ok: false, error: String(err) });
  }
}

/**
 * Who a token belongs to: { admin, me, readOnly } where me is a people id
 * for a person's own key, '' otherwise; null for an unknown token, for the
 * shared key once it is off, and for the key of a person who is deleted or
 * not active in People. A person's admin and viewer (read only) rights come
 * from their roles in People, so the admin changes them in the app.
 */
function user_(token) {
  const props = PropertiesService.getScriptProperties();
  if (!token || typeof token !== 'string') return null;
  if (token === props.getProperty('ADMIN_TOKEN')) return { admin: true, me: '', readOnly: false };
  if (token === props.getProperty('API_TOKEN')) {
    return props.getProperty('SHARED_KEY_OFF') === '1' ? null : { admin: false, me: '', readOnly: false };
  }
  const me = personTokens_()[token];
  if (!me) return null;
  const person = personRow_(me);
  if (!person || person.deleted === '1' || person.active === '0') return null;
  const roles = person.roles.split(',').map(function (r) { return r.trim(); });
  const readOnly = roles.indexOf('viewer') >= 0;
  return { admin: !readOnly && roles.indexOf('admin') >= 0, me: me, readOnly: readOnly };
}

/** A people row as { deleted, active, roles } text, or null. */
function personRow_(id) {
  const sheet = ensureSheet_('people', false);
  if (sheet.getLastRow() < 2) return null;
  const header = readHeader_(sheet);
  const values = sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues();
  const col = function (name) { return header.indexOf(name); };
  const r = values.filter(function (v) { return text_(v[col('id')]) === id; })[0];
  if (!r) return null;
  return { deleted: text_(r[col('deleted')]), active: text_(r[col('active')]), roles: text_(r[col('roles')]) };
}

/** Personal tokens as token -> people id, in the PERSON_TOKENS property. */
function personTokens_() {
  return JSON.parse(PropertiesService.getScriptProperties().getProperty('PERSON_TOKENS') || '{}');
}

/**
 * The token of a person's own key, made on first use. [renew] makes a new
 * one and turns the old one off (a lost phone, a key sent to someone else).
 */
function personToken_(personId, renew) {
  if (!personId) throw new Error('No person');
  const tokens = personTokens_();
  const existing = Object.keys(tokens).filter(function (t) { return tokens[t] === personId; });
  if (existing.length && !renew) return existing[0];
  existing.forEach(function (t) { delete tokens[t]; });
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
 * [user] is { admin, me, readOnly } from user_(). A read only key changes
 * nothing: every row it sends is denied. Only the admin changes the tables
 * in ADMIN_ONLY_TABLES (documents, projects, intervals). In PERSONAL_TABLES (competencies) a
 * person gets, adds and changes only the rows of their own person_id, and
 * their change clears verified. The admin changes anything. Others
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
        if (user.readOnly || (!admin && ADMIN_ONLY_TABLES.indexOf(table) >= 0)) {
          if (at !== undefined) rejected.push(at);
          denied[table].push(row.id);
          return;
        }
        const personal = PERSONAL_TABLES.indexOf(table) >= 0;
        if (personal && !admin && !(me && text_(row.person_id) === me &&
          (at === undefined || text_(values[at][col.person_id]) === me))) {
          if (at !== undefined) rejected.push(at);
          denied[table].push(row.id);
          return;
        }
        const own = at !== undefined && !!me && (personal || text_(values[at][col.created_by]) === me);
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
            return admin ? text_(row.created_by) || me : me;
          }
          // A person's own change is checked again by the admin.
          if (personal && !admin && (name === 'verified' || name === 'verified_by')) return '';
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
        if (PERSONAL_TABLES.indexOf(table) >= 0 && !admin && !(me && text_(r[col.person_id]) === me)) return;
        if (s > from || rejected.indexOf(i) >= 0) rows.push(toObject_(header, r));
      });
      pulled[table] = rows;
      maxSeq[table] = max;
    });

    props.setProperty('SEQ', String(seq));
    return { ok: true, admin: !!admin, me: me, readOnly: !!user.readOnly, accepted: accepted, denied: denied, pulled: pulled, seq: maxSeq };
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

// -------------------------------------------------------------- documents

/**
 * Starts an upload of a document into the Drive folder DOCUMENT_FOLDER and
 * returns Drive's one-time upload address; the admin's app sends the file
 * straight there, so its size is not limited by this script. The app then
 * asks documentInfo for the new file.
 */
function documentUpload_(req) {
  const name = String(req.name || 'document');
  const mime = String(req.mimeType || 'application/octet-stream');
  const res = UrlFetchApp.fetch('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true', {
    method: 'post',
    contentType: 'application/json; charset=UTF-8',
    headers: {
      Authorization: 'Bearer ' + ScriptApp.getOAuthToken(),
      'X-Upload-Content-Type': mime,
      'X-Upload-Content-Length': String(Number(req.size) || 0),
    },
    payload: JSON.stringify({ name: name, mimeType: mime, parents: [folder_(DOCUMENT_FOLDER).getId()] }),
    muteHttpExceptions: true,
  });
  const headers = res.getAllHeaders();
  const location = headers.Location || headers.location;
  if (res.getResponseCode() !== 200 || !location) {
    return { ok: false, error: 'Drive refused the upload (' + res.getResponseCode() + ')' };
  }
  return { ok: true, upload_url: location };
}

/**
 * What the app stores about a Drive file: name, type, size and version
 * (last change). Google Docs, Sheets and Slides are handed out as PDF.
 */
function documentInfo_(fileId) {
  if (!fileId) return { ok: false, error: 'No Drive file' };
  let file;
  try {
    file = DriveApp.getFileById(fileId);
  } catch (err) {
    return { ok: false, error: 'This Drive file cannot be opened by the logbook\'s Google account' };
  }
  const google = isGoogleFile_(file);
  return {
    ok: true,
    drive_file_id: fileId,
    file_name: google ? file.getName() + '.pdf' : file.getName(),
    mime_type: google ? 'application/pdf' : file.getMimeType(),
    size_bytes: google ? '' : String(file.getSize()),
    file_version: file.getLastUpdated().toISOString(),
    url: file.getUrl(),
  };
}

function isGoogleFile_(file) {
  return String(file.getMimeType()).indexOf('application/vnd.google-apps') === 0;
}

/**
 * One piece of a document, base64, from byte `offset` (at most `length`
 * bytes, DOCUMENT_PART by default); `size` is the whole file's. Only files listed in the documents tab, so a link cannot read
 * other Drive files.
 */
function documentPart_(req) {
  const fileId = String(req.drive_file_id || '');
  if (!fileId || documentIds_().indexOf(fileId) < 0) return { ok: false, error: 'Unknown document' };
  const file = DriveApp.getFileById(fileId);
  const version = file.getLastUpdated().toISOString();
  if (isGoogleFile_(file)) {
    const bytes = file.getAs('application/pdf').getBytes();
    return { ok: true, offset: 0, size: bytes.length, version: version, data: Utilities.base64Encode(bytes) };
  }
  const size = Number(file.getSize());
  const offset = Math.max(0, Number(req.offset) || 0);
  if (offset >= size) return { ok: true, offset: offset, size: size, version: version, data: '' };
  const length = Math.min(Number(req.length) || DOCUMENT_PART, DOCUMENT_PART);
  const end = Math.min(offset + length, size) - 1;
  const res = UrlFetchApp.fetch('https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(fileId) + '?alt=media&supportsAllDrives=true', {
    headers: { Authorization: 'Bearer ' + ScriptApp.getOAuthToken(), Range: 'bytes=' + offset + '-' + end },
    muteHttpExceptions: true,
  });
  const code = res.getResponseCode();
  if (code !== 200 && code !== 206) return { ok: false, error: 'Drive answered ' + code };
  let bytes = res.getContent();
  // A server that ignores Range sends the whole file.
  if (code === 200 && offset > 0) bytes = bytes.slice(offset, end + 1);
  return { ok: true, offset: offset, size: size, version: version, data: Utilities.base64Encode(bytes) };
}

/** Drive ids of the documents not deleted. */
function documentIds_() {
  const sheet = ensureSheet_('documents', false);
  if (sheet.getLastRow() < 2) return [];
  const header = readHeader_(sheet);
  const col = header.indexOf('drive_file_id');
  const del = header.indexOf('deleted');
  return sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues()
    .filter(function (r) { return String(r[del]) !== '1'; })
    .map(function (r) { return String(r[col]); })
    .filter(String);
}

/**
 * Hourly trigger: a document changed in Drive gets its new version and size
 * in the documents tab, so every app downloads it again on its next sync.
 */
function refreshDocuments() {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const sheet = ensureSheet_('documents', false);
    if (sheet.getLastRow() < 2) return 0;
    const header = readHeader_(sheet);
    const col = {};
    header.forEach(function (name, i) { col[name] = i; });
    const values = sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues();
    const props = PropertiesService.getScriptProperties();
    let seq = Number(props.getProperty('SEQ') || 0);
    const changed = {};
    values.forEach(function (r, i) {
      const id = String(r[col.drive_file_id] || '');
      if (!id || String(r[col.deleted]) === '1') return;
      const info = documentInfo_(id);
      if (!info.ok || info.file_version === text_(r[col.file_version])) return;
      seq += 1;
      r[col.file_version] = info.file_version;
      r[col.size_bytes] = info.size_bytes;
      r[col.updated_at] = new Date().toISOString();
      r[col.server_seq] = String(seq);
      changed[i] = true;
    });
    writeChanged_(sheet, values, changed, values.length);
    props.setProperty('SEQ', String(seq));
    return Object.keys(changed).length;
  } finally {
    lock.releaseLock();
  }
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

// ---------------------------------------------- old maintenance import

const OLD_MAINTENANCE = '1pLX_T4Vdv_4bP-69eEmOdRy2OjZrFRSuHPInY9CEbtA';

// Old AppSheet columns, in order after Timestamp, *ID and Dron number.
const OLD_MAINTENANCE_COLUMNS = ['arm_assembly', 'center_plate', 'propulsion_system', 'load_assembly', 'leg_assembly', 'power_system', 'fts'];

/**
 * Run once from the editor: copies the old AppSheet "Maintenance" sheet into
 * the maintenance tab. The old sheet is only read. Safe to rerun: rows keep
 * the same ids and are overwritten, unless they were edited in the app since.
 */
function importOldMaintenance(spreadsheetId) {
  const sheet = SpreadsheetApp.openById(spreadsheetId || OLD_MAINTENANCE).getSheets()[0];
  const out = buildImportedMaintenance_(sheet.getDataRange().getDisplayValues(), aircraftIds_());
  const res = sync_({ push: { aircraft: out.aircraft, maintenance: out.rows }, since: {} }, { admin: true, me: '' });
  Logger.log('Imported ' + res.accepted.maintenance.length + ' maintenance rows, ' + out.aircraft.length + ' new drones.');
  return res.accepted.maintenance.length;
}

/** Old sheet rows (header first) -> maintenance rows. */
function buildImportedMaintenance_(rows, aircraftIds) {
  const updatedAt = '2026-11-01T00:00:00.000Z';
  const aircraft = [];
  const out = [];
  rows.slice(1).forEach(function (r) {
    const at = anyTimestamp_(r[0]);
    const drone = String(r[2] === undefined ? '' : r[2]).trim();
    if (!at || !drone) return;
    if (!aircraftIds[drone]) {
      aircraftIds[drone] = 'import-aircraft-' + drone;
      aircraft.push({ id: aircraftIds[drone], updated_at: updatedAt, deleted: 0, name: drone, active: 1 });
    }
    const oldId = String(r[1] === undefined ? '' : r[1]).trim();
    const row = {
      id: 'import-maintenance-' + (oldId || drone + '-' + at.replace(/\D/g, '')),
      updated_at: updatedAt,
      deleted: 0,
      performed_at: at,
      aircraft_id: aircraftIds[drone],
      technician_id: '',
      notes: 'Imported from the old AppSheet table',
    };
    OLD_MAINTENANCE_COLUMNS.forEach(function (c, i) {
      const v = String(r[i + 3] === undefined ? '' : r[i + 3]).trim();
      row[c] = v.toLowerCase() === 'checked' ? 'Checked' : v;
    });
    out.push(row);
  });
  return { rows: out, aircraft: aircraft };
}

// -------------------------------------------- Inspection LogBook import

const OLD_INSPECTIONS = '1lvmAEMN34PAOrhTQ4FVdwH2R-I6y8jvoy0JpCZ72fSw';

/**
 * Run once from the editor: copies the "Inspection_LogBook" sheet (Date,
 * Project, Dron, TakeOff, Land, RP, PA, NOTES) into the flights tab as
 * inspection flights. Missing projects, drones and people are added; the
 * drones get usage "inspection". Drones with no usage yet were all on cargo
 * flights and get "cargo", so each logbook offers only its own drones.
 * The old sheet is only read. Safe to rerun.
 */
function importInspectionLogbook(spreadsheetId) {
  const sheet = SpreadsheetApp.openById(spreadsheetId || OLD_INSPECTIONS).getSheets()[0];
  const out = buildImportedInspections_(sheet.getDataRange().getDisplayValues(), {
    aircraft: refRows_('aircraft'),
    projects: refRows_('projects'),
    people: refRows_('people'),
  }, new Date().toISOString());
  const res = sync_({ push: out, since: {} }, { admin: true, me: '' });
  const n = function (t) { return (res.accepted[t] || []).length; };
  Logger.log('Imported ' + n('flights') + ' inspection flights; ' + n('aircraft') + ' drones, ' +
    n('projects') + ' projects and ' + n('people') + ' people added or updated.');
  return n('flights');
}

/** Rows of a reference tab that are not deleted, as objects. */
function refRows_(table) {
  const sheet = ensureSheet_(table, false);
  const header = readHeader_(sheet);
  if (sheet.getLastRow() < 2) return [];
  return sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues()
    .map(function (r) { return toObject_(header, r); })
    .filter(function (o) { return o.id && o.deleted !== '1'; });
}

/**
 * Sheet rows (header first) to flights, plus the projects, drones and
 * people they need. [ref] holds the current aircraft, projects and people
 * rows; [now] is the updated_at of drones whose usage changes.
 */
function buildImportedInspections_(rows, ref, now) {
  const updatedAt = '2026-11-01T00:00:00.000Z';
  const header = rows[0].map(function (h) { return String(h).trim().toLowerCase(); });
  const at = function (name) { return header.findIndex(function (h) { return h.indexOf(name) === 0; }); };
  const idx = { id: header.indexOf('id'), date: at('date'), project: at('project'), drone: at('dron'),
    takeoff: at('takeoff'), land: at('land'), rp: at('rp'), pa: at('pa'), notes: at('notes') };
  const get = function (r, k) { return idx[k] < 0 ? '' : String(r[idx[k]] === undefined ? '' : r[idx[k]]).trim(); };
  const sys = function (id) { return { id: id, updated_at: updatedAt, deleted: 0 }; };
  const out = { aircraft: [], projects: [], people: [], flights: [] };
  const byName = function (list) {
    const m = {};
    list.forEach(function (o) { m[String(o.name).trim().toLowerCase()] = o; });
    return m;
  };
  const drones = byName(ref.aircraft);
  const projects = byName(ref.projects);
  const people = byName(ref.people);
  const slug = function (s) { return s.replace(/[^A-Za-z0-9]+/g, '-').toLowerCase(); };

  // Drones flown before the usage column: every one was a cargo drone.
  ref.aircraft.forEach(function (d) {
    if (!String(d.usage || '').trim()) {
      d.usage = 'cargo';
      out.aircraft.push({ id: d.id, updated_at: now, usage: 'cargo' });
    }
  });
  const drone = function (name) {
    const key = name.toLowerCase();
    let d = drones[key];
    if (!d) {
      d = drones[key] = Object.assign(sys('import-aircraft-' + slug(name)), { name: name, active: 1, usage: 'inspection' });
      out.aircraft.push(d);
    } else if (String(d.usage).split(',').indexOf('inspection') < 0) {
      d.usage = (d.usage ? d.usage + ',' : '') + 'inspection';
      const pending = out.aircraft.filter(function (a) { return a.id === d.id; })[0];
      if (pending) pending.usage = d.usage;
      else out.aircraft.push({ id: d.id, updated_at: now, usage: d.usage });
    }
    return d.id;
  };
  const project = function (name) {
    if (!name) return '';
    const key = name.toLowerCase();
    if (!projects[key]) {
      projects[key] = Object.assign(sys('import-project-' + slug(name)), { name: name, active: 1 });
      out.projects.push(projects[key]);
    }
    return projects[key].id;
  };
  const person = function (name) {
    if (!name) return '';
    const key = name.toLowerCase();
    if (!people[key]) {
      people[key] = Object.assign(sys('import-person-' + slug(name)), { name: name, roles: 'pilot', active: 1 });
      out.people.push(people[key]);
    }
    return people[key].id;
  };

  rows.slice(1).forEach(function (r, i) {
    const date = sheetDate_(get(r, 'date'));
    const takeoff = clock_(get(r, 'takeoff'));
    const land = clock_(get(r, 'land'));
    if (!date || !get(r, 'drone')) return;
    const id = 'import-inspection-' + (get(r, 'id') || date + '-' + takeoff.replace(/\D/g, '') + '-' + i);
    out.flights.push(Object.assign(sys(id), {
      date: date,
      kind: 'inspection',
      project_id: project(get(r, 'project')),
      aircraft_id: drone(get(r, 'drone')),
      takeoff_at: takeoff,
      landing_at: land,
      duration_s: seconds_(takeoff, land),
      rp_id: person(get(r, 'rp')),
      pa_id: person(get(r, 'pa')),
      notes: get(r, 'notes'),
    }));
  });
  return out;
}

/** "08/10/2026", "12.10.2026" (day first) or "2026-10-12" -> "2026-10-12". */
function sheetDate_(v) {
  const t = String(v || '').trim();
  let m = t.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return m[1] + '-' + m[2] + '-' + m[3];
  m = t.match(/^(\d{1,2})[\/.](\d{1,2})[\/.](\d{4})/);
  if (!m) return '';
  return m[3] + '-' + ('0' + m[2]).slice(-2) + '-' + ('0' + m[1]).slice(-2);
}

/** "3:14:15" or "03:14" -> "03:14:15" / "03:14:00"; anything else -> "". */
function clock_(v) {
  const m = String(v || '').trim().match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  return m ? ('0' + m[1]).slice(-2) + ':' + m[2] + ':' + (m[3] || '00') : '';
}

/** Seconds from take-off to landing, past midnight when landing is earlier. */
function seconds_(takeoff, land) {
  if (!takeoff || !land) return '';
  const s = function (c) { const p = c.split(':').map(Number); return p[0] * 3600 + p[1] * 60 + p[2]; };
  const d = s(land) - s(takeoff);
  return d >= 0 ? d : d + 86400;
}

// --------------------------------------------------------------- Firebase

/**
 * Moving to Firebase. Paste the two values from the Firebase console
 * (Project settings > General: "Project ID" and "Web API key"), save, then
 * run moveToFirebase() and, after it, installFirebaseTriggers().
 */
const FIREBASE_PROJECT_ID = 'pilotlogbook-dbda6';
const FIREBASE_API_KEY = 'AIzaSyDMAoZ2aykFFpEsn-Rmz1rAVC-dwTVOKi0';

// FIRESTORE-RULES-START (kept equal to firebase/firestore.rules by a test)
const FIRESTORE_RULES = String.raw`rules_version = '2';

// Pilot Logbook security rules for Cloud Firestore. Every table of
// app/lib/data/schema.dart is a collection; a document's id is the row id.
//
// Who is who: each access key is a Firebase Auth account (email + password
// packed into the key). members/{uid} says whose key it is:
//   kind 'master'  the master admin key: changes and deletes everything;
//   kind 'shared'  the shared pilots' key: only adds rows;
//   kind 'person'  a person's own key (person_id): valid only while that
//                  person is active and not deleted in people. Roles come
//                  from people.roles: 'admin' = every right, 'viewer' = read
//                  only. Others change only the rows they added.
// active == false turns a key off. These are the rules Code.gs had for
// the Google Sheets backend.
//
// Kept equal to FIRESTORE_RULES in apps_script/Code.gs by a test.
service cloud.firestore {
  match /databases/{database}/documents {

    function doc(collection, id) {
      return /databases/$(database)/documents/$(collection)/$(id);
    }

    function str(v) {
      return v is string ? v : '';
    }

    // Sheets kept 1/0 as text; the app writes numbers.
    function isOn(v) {
      return v == 1 || v == '1' || v == true;
    }

    function isOff(v) {
      return v == 0 || v == '0' || v == false;
    }

    function hasRole(p, role) {
      return str(p.get('roles', '')).matches('(.*,)?\\s*' + role + '\\s*(,.*)?');
    }

    // The caller's rights: ok (key valid), admin, viewer and me (people id,
    // '' for the master and shared keys).
    function account() {
      let m = get(doc('members', request.auth.uid)).data;
      let person = m.kind == 'person';
      let p = person ? get(doc('people', m.person_id)).data : {};
      return {
        'ok': m.active == true
          && (!person || (!isOn(p.get('deleted', 0)) && !isOff(p.get('active', 1)))),
        'admin': m.kind == 'master'
          || (person && hasRole(p, 'admin') && !hasRole(p, 'viewer')),
        'viewer': person && hasRole(p, 'viewer'),
        'me': person ? m.person_id : ''
      };
    }

    function signedIn() {
      return request.auth != null
        && exists(doc('members', request.auth.uid));
    }

    function valid() {
      return signedIn() && account().ok;
    }

    function admin() {
      return valid() && account().admin;
    }

    // The app's keys and who they belong to: only the admin.
    match /members/{uid} {
      allow get: if request.auth != null
        && (request.auth.uid == uid || admin());
      allow list, create, update, delete: if admin();
    }

    // meta/changes: per table, when it last changed (the app skips tables
    // that did not). meta/config: settings written by the migration.
    match /meta/{name} {
      allow read: if valid();
      allow create, update: if name == 'changes'
        && valid() && !account().viewer;
    }

    match /{table}/{id} {
      function isTable() {
        return table in ['people', 'projects', 'aircraft', 'batteries',
          'mission_types', 'flights', 'checklist_templates', 'checklist_items',
          'checks', 'check_answers', 'daily_checks_fb3', 'daily_checks_m30t',
          'faults', 'fault_repairs', 'fault_signoffs', 'fault_photos',
          'maintenance', 'maintenance_intervals', 'torque_specs',
          'competencies', 'documents'];
      }

      // Only the admin adds to, changes or deletes these.
      function adminOnly() {
        return table in ['documents', 'maintenance_intervals', 'projects'];
      }

      // One person's own rows (person_id): only they and the admin.
      function personal() {
        return table in ['competencies'];
      }

      allow get, list: if isTable() && valid()
        && (!personal() || account().admin
          || resource.data.get('person_id', '') == account().me);

      allow create: if isTable() && writable(null);
      allow update: if isTable() && writable(resource.data);
      // Rows are never removed, only marked deleted.
      allow delete: if false;

      function writable(old) {
        let d = request.resource.data;
        let a = account();
        return valid() && !a.viewer
          && d.get('id', '') == id
          && d.get('server_time', null) == request.time
          // The newer edit wins: an older one is refused, and the app then
          // takes the version stored here.
          && (old == null || str(d.get('updated_at', '')) >= str(old.get('updated_at', '')))
          && (a.admin || (!adminOnly() && (personal() ? ownPersonal(old, d, a) : ownRow(old, d, a))));
      }

      // A new row is marked as the caller's and is not deleted; a row is
      // changed (or deleted) only by the person who added it.
      function ownRow(old, d, a) {
        let by = d.get('created_by', null);
        return old == null
          ? (by == a.me || (a.me == '' && by == null)) && !isOn(d.get('deleted', 0))
          : a.me != '' && old.get('created_by', '') == a.me && by == a.me;
      }

      // Only the person's own rows; only the admin marks one verified.
      function ownPersonal(old, d, a) {
        return a.me != ''
          && d.get('person_id', '') == a.me
          && (old == null || old.get('person_id', '') == a.me)
          && !isOn(d.get('verified', 0))
          && str(d.get('verified_by', '')) == '';
      }
    }
  }
}
`;
// FIRESTORE-RULES-END

// STORAGE-RULES-START (kept equal to firebase/storage.rules by a test)
const STORAGE_RULES = String.raw`rules_version = '2';

// Pilot Logbook files in Cloud Storage for Firebase: fault photos and the
// documents every pilot needs. Who may do what comes from the same
// members/{uid} and people documents as firestore.rules.
//
// Kept equal to STORAGE_RULES in apps_script/Code.gs by a test.
service firebase.storage {
  match /b/{bucket}/o {

    function member() {
      return firestore.get(/databases/(default)/documents/members/$(request.auth.uid)).data;
    }

    function valid() {
      return request.auth != null && member().active == true;
    }

    function admin() {
      let m = member();
      let roles = m.kind == 'person'
        ? firestore.get(/databases/(default)/documents/people/$(m.person_id)).data.get('roles', '')
        : '';
      return m.kind == 'master' || (roles is string
        && roles.matches('(.*,)?\\s*admin\\s*(,.*)?')
        && !roles.matches('(.*,)?\\s*viewer\\s*(,.*)?'));
    }

    // photos/<fault_photos id>.jpg, added from any device, never replaced.
    match /photos/{name} {
      allow read: if valid();
      allow create: if valid()
        && request.resource.size < 30 * 1024 * 1024
        && request.resource.contentType.matches('image/.*');
    }

    // documents/<folder>/<file name>: only the admin adds them.
    match /documents/{folder}/{name} {
      allow read: if valid();
      allow create, update, delete: if valid() && admin();
    }
  }
}
`;
// STORAGE-RULES-END

/**
 * Run once (again when it says so): moves everything to Firebase.
 *  1. Publishes the security rules.
 *  2. Stops syncing with this spreadsheet; from now on every app that
 *     syncs here gets its new Firebase access key instead, and syncs there.
 *  3. Makes a Firebase key for every access key (master admin, shared
 *     pilots' key, each person's own key).
 *  4. Copies every tab to Firestore.
 *  5. Copies fault photos and document files from Drive to Firebase
 *     Storage; when this takes long it stops and asks to be run again.
 * The spreadsheet itself is only read, and kept as it is.
 */
function moveToFirebase() {
  const fb = firebaseConfig_();
  const props = PropertiesService.getScriptProperties();
  const started = Date.now();
  const done = [];

  try {
    deployRules_(fb, 'cloud.firestore', 'firestore.rules', FIRESTORE_RULES);
    done.push('Firestore rules published');
  } catch (err) {
    done.push('Firestore rules NOT published (' + err + '): paste firebase/firestore.rules in Firestore > Rules');
  }

  props.setProperty('FIREBASE_MOVED', '1');

  if (!props.getProperty('FIREBASE_KEYS')) {
    props.setProperty('FIREBASE_KEYS', JSON.stringify(makeFirebaseKeys_(fb)));
    done.push('access keys made');
  }

  if (props.getProperty('FIREBASE_TABLES_DONE') !== '1') {
    const counts = copyTablesToFirestore_(fb);
    props.setProperty('FIREBASE_TABLES_DONE', '1');
    done.push('tables copied: ' + Object.keys(counts).map(function (t) { return t + ' ' + counts[t]; }).join(', '));
  }

  let files;
  try {
    deployRules_(fb, 'firebase.storage/' + fb.bucket, 'storage.rules', STORAGE_RULES);
    files = copyFilesToStorage_(fb, started);
    done.push('files copied: ' + files.copied + (files.failed.length ? ', not copied: ' + files.failed.join('; ') : ''));
  } catch (err) {
    files = { left: 0 };
    done.push('files NOT copied (' + err + '): is Storage turned on in Firebase (Blaze plan)?');
  }

  const keys = JSON.parse(props.getProperty('FIREBASE_KEYS'));
  const master = keys[props.getProperty('ADMIN_TOKEN')];
  Logger.log(done.join('\n'));
  if (files.left) {
    Logger.log('NOT DONE YET: ' + files.left + ' files left. Run moveToFirebase again.');
  } else {
    Logger.log('DONE. Every app switches to Firebase by itself on its next sync.\nMaster admin key (only for you):\n' + master);
  }
  return { done: done, left: files.left, masterKey: master };
}

/** The project's ids; stops with a message while they are not filled in. */
function firebaseConfig_() {
  const props = PropertiesService.getScriptProperties();
  const project = FIREBASE_PROJECT_ID || props.getProperty('FIREBASE_PROJECT_ID') || '';
  const apiKey = FIREBASE_API_KEY || props.getProperty('FIREBASE_API_KEY') || '';
  if (!project || !apiKey) {
    throw new Error('Fill in FIREBASE_PROJECT_ID and FIREBASE_API_KEY at the Firebase section of Code.gs first');
  }
  return {
    project: project,
    apiKey: apiKey,
    bucket: props.getProperty('FIREBASE_BUCKET') || project + '.firebasestorage.app',
    docs: 'projects/' + project + '/databases/(default)/documents',
  };
}

/** A Google API call as the script's owner (who owns the Firebase project). */
function googleApi_(fb, method, url, body, contentType) {
  const opts = {
    method: method,
    headers: { Authorization: 'Bearer ' + ScriptApp.getOAuthToken(), 'X-Goog-User-Project': fb.project },
    muteHttpExceptions: true,
  };
  if (body !== undefined) {
    opts.contentType = contentType || 'application/json';
    opts.payload = contentType ? body : JSON.stringify(body);
  }
  const res = UrlFetchApp.fetch(url, opts);
  const code = res.getResponseCode();
  const text = res.getContentText();
  if (code < 200 || code >= 300) throw new Error(method + ' ' + url.split('?')[0] + ': ' + code + ' ' + text.slice(0, 300));
  return text ? JSON.parse(text) : {};
}

function deployRules_(fb, release, fileName, source) {
  const base = 'https://firebaserules.googleapis.com/v1/projects/' + fb.project;
  const ruleset = googleApi_(fb, 'post', base + '/rulesets', { source: { files: [{ name: fileName, content: source }] } });
  const name = 'projects/' + fb.project + '/releases/' + release;
  try {
    googleApi_(fb, 'patch', base + '/releases/' + release, { release: { name: name, rulesetName: ruleset.name } });
  } catch (err) {
    googleApi_(fb, 'post', base + '/releases', { name: name, rulesetName: ruleset.name });
  }
}

/** Writes in pieces of at most 400 (Firestore takes 500 per commit). */
function commitAll_(fb, writes) {
  for (let i = 0; i < writes.length; i += 400) {
    googleApi_(fb, 'post', 'https://firestore.googleapis.com/v1/' + fb.docs + ':commit', { writes: writes.slice(i, i + 400) });
  }
}

/** A write replacing a document, with server_time set by Firestore. */
function firestoreUpsert_(fb, path, fields, stampField) {
  const out = {};
  Object.keys(fields).forEach(function (k) { out[k] = firestoreValue_(fields[k]); });
  return {
    update: { name: fb.docs + '/' + path, fields: out },
    updateTransforms: [{ fieldPath: stampField || 'server_time', setToServerValue: 'REQUEST_TIME' }],
  };
}

/** A write that only marks tables changed in meta/changes. */
function firestoreStamp_(fb, tables) {
  return {
    update: { name: fb.docs + '/meta/changes', fields: {} },
    updateMask: { fieldPaths: [] },
    updateTransforms: tables.map(function (t) { return { fieldPath: t, setToServerValue: 'REQUEST_TIME' }; }),
  };
}

function firestoreValue_(v) {
  if (v === null || v === undefined || v === '') return { nullValue: null };
  if (typeof v === 'boolean') return { booleanValue: v };
  return { stringValue: String(v) };
}

/** Every tab's rows as Firestore documents, text as in the sheet. */
function copyTablesToFirestore_(fb) {
  const counts = {};
  Object.keys(SCHEMA).forEach(function (table) {
    const sheet = ensureSheet_(table, false);
    const writes = [];
    if (sheet.getLastRow() > 1) {
      const header = readHeader_(sheet);
      sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues().forEach(function (r) {
        const row = toObject_(header, r);
        if (!row.id || row.id.indexOf('/') >= 0) return;
        delete row.server_seq;
        writes.push(firestoreUpsert_(fb, table + '/' + row.id, row));
      });
    }
    counts[table] = writes.length;
    writes.push(firestoreStamp_(fb, [table]));
    commitAll_(fb, writes);
  });
  return counts;
}

/** A random text of [n] letters and digits. */
function randomText_(n) {
  let s = '';
  while (s.length < n) s += Utilities.getUuid().replace(/-/g, '');
  return s.slice(0, n);
}

/** The access key text for a Firebase account, as FirebaseKey in the app. */
function firebaseKey_(fb, id, secret) {
  return 'PL2-' + Utilities.base64EncodeWebSafe([fb.project, fb.apiKey, id, secret].join(' '), Utilities.Charset.UTF_8).replace(/=+$/, '');
}

/** A new Firebase Auth account and its members document; returns the key. */
function newFirebaseKey_(fb, member) {
  const id = randomText_(12);
  const secret = randomText_(24);
  const res = UrlFetchApp.fetch('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=' + fb.apiKey, {
    method: 'post',
    contentType: 'application/json',
    payload: JSON.stringify({ email: 'key-' + id + '@pilotlogbook.app', password: secret, returnSecureToken: true }),
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() !== 200) {
    throw new Error('Firebase Authentication refused a new key (' + res.getContentText().slice(0, 200) + '). Is Email/Password sign-in turned on?');
  }
  const uid = JSON.parse(res.getContentText()).localId;
  const key = firebaseKey_(fb, id, secret);
  const fields = { uid: uid, key: key };
  Object.keys(member).forEach(function (k) { fields[k] = member[k]; });
  commitAll_(fb, [firestoreUpsert_(fb, 'members/' + uid, fields, 'created_at')]);
  return key;
}

/** A Firebase key for every key of this script: old token -> new key. */
function makeFirebaseKeys_(fb) {
  const props = PropertiesService.getScriptProperties();
  const keys = {};
  const admin = props.getProperty('ADMIN_TOKEN');
  if (admin) keys[admin] = newFirebaseKey_(fb, { kind: 'master', active: true });
  const shared = props.getProperty('API_TOKEN');
  if (shared) keys[shared] = newFirebaseKey_(fb, { kind: 'shared', active: props.getProperty('SHARED_KEY_OFF') !== '1' });
  const people = personTokens_();
  Object.keys(people).forEach(function (token) {
    keys[token] = newFirebaseKey_(fb, { kind: 'person', person_id: people[token], active: true });
  });
  return keys;
}

/**
 * Copies fault photos and document files from Drive to Firebase Storage
 * and notes where in their rows. Stops after about 4.5 minutes (Apps Script
 * allows 6), returning how many are left.
 */
function copyFilesToStorage_(fb, started) {
  const props = PropertiesService.getScriptProperties();
  const doneIds = JSON.parse(props.getProperty('FIREBASE_FILES_DONE') || '{}');
  const todo = [];
  ['fault_photos', 'documents'].forEach(function (table) {
    const sheet = ensureSheet_(table, false);
    if (sheet.getLastRow() < 2) return;
    const header = readHeader_(sheet);
    sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).getValues().forEach(function (r) {
      const row = toObject_(header, r);
      if (row.drive_file_id && row.deleted !== '1' && !doneIds[row.id]) todo.push({ table: table, row: row });
    });
  });
  let copied = 0;
  const failed = [];
  for (let i = 0; i < todo.length; i++) {
    if (Date.now() - started > 270000) {
      props.setProperty('FIREBASE_FILES_DONE', JSON.stringify(doneIds));
      return { copied: copied, failed: failed, left: todo.length - i };
    }
    const t = todo[i];
    try {
      const file = DriveApp.getFileById(t.row.drive_file_id);
      const blob = t.table === 'documents' && isGoogleFile_(file) ? file.getAs('application/pdf') : file.getBlob();
      const name = t.table === 'fault_photos'
        ? 'photos/' + t.row.id + '.jpg'
        : 'documents/' + t.row.id + '/' + (t.row.file_name || file.getName()).replace(/[\/\\]/g, '_');
      googleApi_(fb, 'post', 'https://storage.googleapis.com/upload/storage/v1/b/' + encodeURIComponent(fb.bucket) +
        '/o?uploadType=media&name=' + encodeURIComponent(name), blob.getBytes(), blob.getContentType() || 'application/octet-stream');
      const row = {};
      Object.keys(t.row).forEach(function (k) { row[k] = t.row[k]; });
      delete row.server_seq;
      row.storage_path = name;
      row.updated_at = new Date().toISOString();
      commitAll_(fb, [firestoreUpsert_(fb, t.table + '/' + row.id, row), firestoreStamp_(fb, [t.table])]);
      copied++;
    } catch (err) {
      failed.push(t.table + ' ' + t.row.id + ': ' + String(err).slice(0, 120));
    }
    doneIds[t.row.id] = true;
  }
  props.setProperty('FIREBASE_FILES_DONE', JSON.stringify(doneIds));
  commitAll_(fb, [firestoreUpsert_(fb, 'meta/config', { bucket: fb.bucket }, 'updated_at')]);
  return { copied: copied, failed: failed, left: 0 };
}

/**
 * After the move, what this script answers every app: its new key (the
 * app then syncs with Firebase), or, for an unknown key, an error.
 * Null while the data is still here.
 */
function movedAnswer_(token) {
  const props = PropertiesService.getScriptProperties();
  if (props.getProperty('FIREBASE_MOVED') !== '1') return null;
  const keys = JSON.parse(props.getProperty('FIREBASE_KEYS') || '{}');
  const key = typeof token === 'string' ? keys[token] : null;
  if (key) return { ok: false, moved_to: key, error: 'Pilot Logbook moved to Firebase. Update the app.' };
  return { ok: false, error: 'Pilot Logbook is moving to Firebase. Try again in a few minutes, or ask the administrator for a new access key.' };
}

/**
 * Daily: copies every Firestore collection back into its tab, so this
 * spreadsheet stays a readable copy of the data and monthlyBackup() keeps
 * saving it. The app never writes here any more.
 */
function mirrorFromFirebase() {
  const fb = firebaseConfig_();
  Object.keys(SCHEMA).forEach(function (table) {
    const rows = [];
    let pageToken = '';
    do {
      const page = googleApi_(fb, 'get', 'https://firestore.googleapis.com/v1/' + fb.docs + '/' + table +
        '?pageSize=300' + (pageToken ? '&pageToken=' + encodeURIComponent(pageToken) : ''));
      (page.documents || []).forEach(function (d) { rows.push(plainFields_(d.fields || {})); });
      pageToken = page.nextPageToken || '';
    } while (pageToken);
    const sheet = ensureSheet_(table, false);
    const header = readHeader_(sheet);
    const values = rows.map(function (r) {
      return header.map(function (name) {
        if (name === 'server_seq') return r.server_time ? String(Date.parse(r.server_time)) : '';
        const v = r[name];
        return v === null || v === undefined ? '' : String(v);
      });
    });
    if (sheet.getLastRow() > 1) sheet.getRange(2, 1, sheet.getLastRow() - 1, header.length).clearContent();
    if (values.length) {
      const range = sheet.getRange(2, 1, values.length, header.length);
      range.setNumberFormat('@');
      range.setValues(values);
    }
  });
}

function plainFields_(fields) {
  const out = {};
  Object.keys(fields).forEach(function (k) {
    const v = fields[k];
    if ('stringValue' in v) out[k] = v.stringValue;
    else if ('integerValue' in v) out[k] = String(v.integerValue);
    else if ('doubleValue' in v) out[k] = String(v.doubleValue);
    else if ('booleanValue' in v) out[k] = v.booleanValue ? '1' : '0';
    else if ('timestampValue' in v) out[k] = v.timestampValue;
    else out[k] = '';
  });
  return out;
}

/** After moveToFirebase: the daily copy back into this spreadsheet. */
function installFirebaseTriggers() {
  ScriptApp.getProjectTriggers()
    .filter(function (t) {
      return ['mirrorFromFirebase', 'refreshDocuments'].indexOf(t.getHandlerFunction()) >= 0;
    })
    .forEach(function (t) { ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('mirrorFromFirebase').timeBased().everyDays(1).atHour(2).create();
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
