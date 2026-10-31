// Runs Code.gs against in-memory fakes of the Apps Script services.
// Usage: node --test 'apps_script/test/*.test.js'
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class FakeSheet {
  constructor(name) {
    this.name = name;
    this.cells = []; // rows of values, 0-based
  }
  getLastRow() {
    return this.cells.length;
  }
  getLastColumn() {
    return this.cells.reduce((m, r) => Math.max(m, r.length), 0);
  }
  getMaxRows() {
    return Math.max(1000, this.cells.length);
  }
  getMaxColumns() {
    return Math.max(26, this.getLastColumn());
  }
  setFrozenRows() {}
  getRange(row, col, rows, cols) {
    const sheet = this;
    const range = {
      getValues() {
        const out = [];
        for (let r = 0; r < rows; r++) {
          const line = [];
          for (let c = 0; c < cols; c++) {
            const v = (sheet.cells[row - 1 + r] || [])[col - 1 + c];
            line.push(v === undefined ? '' : v);
          }
          out.push(line);
        }
        return out;
      },
      setValues(values) {
        values.forEach((line, r) => {
          const target = (sheet.cells[row - 1 + r] = sheet.cells[row - 1 + r] || []);
          line.forEach((v, c) => (target[col - 1 + c] = v));
        });
        return range;
      },
      setFontWeight: () => range,
      setNumberFormat: () => range,
    };
    return range;
  }
}

function load({ standalone = false, fresh = false, serviceUrl = 'https://script.google.com/macros/s/abc/exec' } = {}) {
  const sheets = {};
  const props = {};
  const files = [];
  let uuid = 0;
  if (standalone && !fresh) props.SPREADSHEET_ID = 'ss1';
  const oldSheets = {};
  const driveFiles = [];
  const spreadsheet = {
    getId: () => 'ss1',
    getName: () => 'Pilot Logbook',
    getUrl: () => 'https://docs.google.com/spreadsheets/d/ss1/edit',
    getSheetByName: (n) => sheets[n] || null,
    insertSheet: (n) => (sheets[n] = new FakeSheet(n)),
  };
  const ctx = {
    SpreadsheetApp: {
      getActive: () => (standalone ? null : spreadsheet),
      openById: (id) =>
        id === 'ss1'
          ? spreadsheet
          : {
              getSheets: () => [{ getDataRange: () => ({ getDisplayValues: () => oldSheets[id] }) }],
              getSheetByName: () => ({ getDataRange: () => ({ getDisplayValues: () => oldSheets[id] }) }),
            },
      create: () => spreadsheet,
    },
    PropertiesService: {
      getScriptProperties: () => ({
        getProperty: (k) => (k in props ? props[k] : null),
        setProperty: (k, v) => (props[k] = String(v)),
      }),
    },
    LockService: { getScriptLock: () => ({ waitLock() {}, releaseLock() {} }) },
    ContentService: {
      MimeType: { JSON: 'json' },
      createTextOutput: (text) => ({ text, setMimeType() { return this; } }),
    },
    ScriptApp: {
      getService: () => ({ getUrl: () => serviceUrl }),
      getProjectTriggers: () => [],
      deleteTrigger() {},
      newTrigger: () => {
        const b = { timeBased: () => b, onMonthDay: () => b, atHour: () => b, create: () => b };
        return b;
      },
    },
    Utilities: {
      getUuid: () => 'token-' + ++uuid,
      formatDate: () => '2026-11',
      base64Decode: (s) => s,
      base64Encode: (s) => s,
      newBlob: (data, type, name) => ({ data, type, name }),
    },
    Session: { getScriptTimeZone: () => 'UTC' },
    DriveApp: {
      getFoldersByName: () => ({ hasNext: () => false }),
      createFolder: (name) => ({
        createFile: (blob) => ({ getId: () => 'f-' + blob.name, getUrl: () => 'https://drive/' + blob.name }),
      }),
      getFileById: (id) => ({
        makeCopy: (name) => files.push(name),
        getBlob: () => ({ getContentType: () => 'image/jpeg', getBytes: () => 'bytes-of-' + id }),
      }),
      getFilesByName: (name) => {
        const found = driveFiles.includes(name);
        return { hasNext: () => found, next: () => ({ getId: () => 'drive-' + name, getUrl: () => 'https://drive/' + name }) };
      },
    },
    Logger: { log() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Code.gs'), 'utf8'), ctx);
  ctx.setup();
  const send = (token) => (body) =>
    JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token, ...body }) } }).text);
  // token-1 is the pilots' link, token-2 the admin link.
  return { ctx, sheets, props, files, post: send('token-2'), pilot: send('token-1'), oldSheets, driveFiles };
}

const flight = (id, updatedAt, extra = {}) => ({
  id,
  updated_at: updatedAt,
  server_seq: null,
  deleted: 0,
  date: '2026-10-28',
  takeoff_at: '13:00:00',
  ...extra,
});

test('setup creates one tab per table with headers', () => {
  const { sheets } = load();
  assert.ok(sheets.flights);
  assert.deepStrictEqual(sheets.flights.cells[0].slice(0, 5), ['id', 'updated_at', 'server_seq', 'deleted', 'created_by']);
});

test('rejects a wrong token', () => {
  const { ctx } = load();
  const out = JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token: 'x', action: 'sync' }) } }).text);
  assert.strictEqual(out.ok, false);
});

test('push inserts rows, assigns sequence numbers and returns them on pull', () => {
  const { post, sheets } = load();
  const out = post({ action: 'sync', push: { flights: [flight('a', '2026-10-28T10:00:00Z')] }, since: { flights: 0 } });
  assert.strictEqual(out.ok, true);
  assert.deepStrictEqual(out.accepted.flights, [{ id: 'a', updated_at: '2026-10-28T10:00:00Z', server_seq: 1 }]);
  assert.strictEqual(out.seq.flights, 1);
  assert.strictEqual(out.pulled.flights[0].takeoff_at, '13:00:00');
  assert.strictEqual(sheets.flights.cells.length, 2);
});

test('pull returns only rows newer than the cursor', () => {
  const { post } = load();
  post({ action: 'sync', push: { flights: [flight('a', 't1'), flight('b', 't1')] }, since: {} });
  const out = post({ action: 'sync', push: {}, since: { flights: 1 } });
  assert.deepStrictEqual(out.pulled.flights.map((r) => r.id), ['b']);
});

test('older update is rejected and the newer row is sent back', () => {
  const { post, sheets } = load();
  post({ action: 'sync', push: { flights: [flight('a', '2026-10-28T12:00:00Z', { notes: 'new' })] }, since: {} });
  const out = post({
    action: 'sync',
    push: { flights: [flight('a', '2026-10-28T11:00:00Z', { notes: 'old' })] },
    since: { flights: 1 },
  });
  assert.deepStrictEqual(out.accepted.flights, []);
  assert.strictEqual(out.pulled.flights[0].notes, 'new');
  assert.strictEqual(sheets.flights.cells.length, 2);
});

test('newer update overwrites the same row in place', () => {
  const { post, sheets } = load();
  post({ action: 'sync', push: { flights: [flight('a', 't1', { notes: 'x' })] }, since: {} });
  post({ action: 'sync', push: { flights: [flight('a', 't2', { notes: 'y' })] }, since: {} });
  assert.strictEqual(sheets.flights.cells.length, 2);
  const header = sheets.flights.cells[0];
  assert.strictEqual(sheets.flights.cells[1][header.indexOf('notes')], 'y');
  assert.strictEqual(sheets.flights.cells[1][header.indexOf('server_seq')], '2');
});

test('monthly backup copies the spreadsheet', () => {
  const { ctx, files } = load();
  ctx.monthlyBackup();
  assert.deepStrictEqual(files, ['Pilot Logbook backup 2026-11']);
});

test('photo upload returns the Drive id', () => {
  const { post } = load();
  const out = post({ action: 'uploadPhoto', name: 'p.jpg', data: 'xx' });
  assert.strictEqual(out.drive_file_id, 'f-p.jpg');
});

test('a standalone script finds the spreadsheet by SPREADSHEET_ID', () => {
  const { post, sheets } = load({ standalone: true });
  const out = post({ action: 'sync', push: { flights: [flight('a', 't1')] }, since: {} });
  assert.strictEqual(out.ok, true);
  assert.strictEqual(sheets.flights.cells.length, 2);
});

test('setup in a fresh standalone script creates the spreadsheet', () => {
  const { sheets, props } = load({ standalone: true, fresh: true });
  assert.strictEqual(props.SPREADSHEET_ID, 'ss1');
  assert.ok(sheets.flights);
});

test('a pilot adds rows but cannot change or delete them', () => {
  const { post, pilot, sheets } = load();
  const added = pilot({ action: 'sync', push: { flights: [flight('a', 't1', { notes: 'x' })] }, since: {} });
  assert.strictEqual(added.admin, false);
  assert.strictEqual(added.accepted.flights.length, 1);
  // The same version again (answer lost on the way) is fine.
  const retry = pilot({ action: 'sync', push: { flights: [flight('a', 't1', { notes: 'x' })] }, since: { flights: 1 } });
  assert.deepStrictEqual(retry.denied.flights, []);
  const edit = pilot({
    action: 'sync',
    push: { flights: [flight('a', 't2', { notes: 'y' }), flight('b', 't2', { deleted: 1 })] },
    since: { flights: 2 },
  });
  assert.deepStrictEqual(edit.accepted.flights, []);
  assert.deepStrictEqual(edit.denied.flights, ['a', 'b']);
  assert.strictEqual(edit.pulled.flights[0].notes, 'x');
  const header = sheets.flights.cells[0];
  assert.strictEqual(sheets.flights.cells.length, 2);
  assert.strictEqual(sheets.flights.cells[1][header.indexOf('notes')], 'x');
  // The admin link may.
  const admin = post({ action: 'sync', push: { flights: [flight('a', 't3', { deleted: 1 })] }, since: {} });
  assert.strictEqual(admin.admin, true);
  assert.strictEqual(admin.accepted.flights.length, 1);
  assert.strictEqual(sheets.flights.cells[1][header.indexOf('deleted')], '1');
});

test('a person\'s own link changes and deletes only that person\'s rows', () => {
  const { post, sheets, ctx } = load();
  const link = post({ action: 'personLink', person_id: 'p-anna' });
  assert.strictEqual(link.ok, true);
  // Asking again gives the same link.
  assert.strictEqual(post({ action: 'personLink', person_id: 'p-anna' }).token, link.token);
  const anna = (body) =>
    JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token: link.token, ...body }) } }).text);
  // Pilots cannot make links.
  assert.strictEqual(anna({ action: 'personLink', person_id: 'p-anna' }).ok, false);

  // The device cannot claim someone else's row.
  const added = anna({ action: 'sync', push: { flights: [flight('a', 't1', { created_by: 'p-bob' })] }, since: {} });
  assert.strictEqual(added.me, 'p-anna');
  assert.strictEqual(added.pulled.flights[0].created_by, 'p-anna');
  post({ action: 'sync', push: { flights: [flight('b', 't1', { created_by: 'p-bob' })] }, since: {} });

  const out = anna({
    action: 'sync',
    push: { flights: [flight('a', 't2', { notes: 'mine' }), flight('b', 't2', { deleted: 1 })] },
    since: { flights: 2 },
  });
  assert.deepStrictEqual(out.accepted.flights.map((r) => r.id), ['a']);
  assert.deepStrictEqual(out.denied.flights, ['b']);
  const h = sheets.flights.cells[0];
  const row = (id) => sheets.flights.cells.find((r) => r[0] === id);
  assert.strictEqual(row('a')[h.indexOf('notes')], 'mine');
  assert.strictEqual(row('a')[h.indexOf('created_by')], 'p-anna');
  assert.strictEqual(row('b')[h.indexOf('deleted')], '0');
  assert.strictEqual(row('b')[h.indexOf('created_by')], 'p-bob');

  // Her own row she can delete.
  anna({ action: 'sync', push: { flights: [flight('a', 't3', { deleted: 1 })] }, since: {} });
  assert.strictEqual(row('a')[h.indexOf('deleted')], '1');
});

test('connectionLink gives the web app URL with the access token', () => {
  const { ctx } = load();
  assert.strictEqual(ctx.connectionLink(), 'https://script.google.com/macros/s/abc/exec?key=token-1');
});

test('connectionLink turns the editor /dev URL into the deployed /exec URL', () => {
  const { ctx } = load({ serviceUrl: 'https://script.google.com/macros/s/abc/dev' });
  assert.strictEqual(ctx.connectionLink(), 'https://script.google.com/macros/s/abc/exec?key=token-1');
});

test('old daily checks: UA and GCS of the same drone and day become one check', () => {
  const { ctx, sheets, post, oldSheets } = load();
  post({ action: 'sync', push: { aircraft: [{ id: 'd18', updated_at: 't', deleted: 0, name: '18' }] }, since: {} });
  oldSheets['1Ka2AUNiKkOdYfyfxFSIuDck5ApH_onn7pZ4Mmmvyew0'] = [
    ['Timestamp', 'Dron №', 'Motors', 'Centre', 'Load', 'Gear', 'Cargo'],
    ['27/10/2026 11:26:53', '18', 'OK', 'Ok', 'Ok', 'Landing gear need to be replaced in future , Ok', 'No cargo'],
    ['29/09/2026 09:56:08', '19', 'Ok.', 'Ok', 'ok', 'Ok', 'N/A'],
  ];
  oldSheets['1Z2oNDvp5NEIgCE3jyhkCOgUz5AvZrpJ0HAtahKq6UO0'] = [
    ['Timestamp', 'Dron', 'GCS', 'Power', 'UA', 'RFD', 'FTS', 'Off', 'Storage'],
    ['27/10/2026 11:37:41', '18', 'Top tablet touchpad', 'Ok', 'Ok', 'Ok', 'Ok', 'Ok', ''],
    ['28/10/2026 08:00:00', '18', 'Ok', 'Ok', 'Ok', 'RCLH timout', 'Ok', 'No', 'No'],
  ];
  assert.strictEqual(ctx.importOldDailyChecks(), 3);
  const cells = sheets.daily_checks_fb3.cells;
  const h = cells[0];
  const rows = cells.slice(1).map((r) => Object.fromEntries(h.map((n, i) => [n, r[i]])));
  const a = rows.find((r) => r.checked_at === '2026-10-27 11:26:53');
  assert.strictEqual(a.aircraft_id, 'd18');
  assert.strictEqual(a.motors_propellers, 'Ok');
  assert.strictEqual(a.landing_gear, 'Landing gear need to be replaced in future , Ok');
  assert.strictEqual(a.cargo_compartment, 'Not used');
  assert.strictEqual(a.power_on_gcs, 'Ok');
  assert.strictEqual(a.external_rf, '');
  assert.match(a.notes, /GCS: Top tablet touchpad/);
  const gcsOnly = rows.find((r) => r.checked_at === '2026-10-28 08:00:00');
  assert.strictEqual(gcsOnly.rfd_rclh, 'RCLH timout');
  assert.strictEqual(gcsOnly.switch_off, 'Not used');
  assert.strictEqual(gcsOnly.motors_propellers, '');
  // Drone 19 was missing and is added.
  assert.ok(sheets.aircraft.cells.some((r) => r.includes('19')));
  // Running it again does not duplicate.
  ctx.importOldDailyChecks();
  assert.strictEqual(sheets.daily_checks_fb3.cells.length, 4);
});

const rowsOf = (sheet) => {
  const [h, ...rows] = sheet.cells;
  return rows.map((r) => Object.fromEntries(h.map((n, i) => [n, r[i]])));
};

test('old AppSheet fault reports become faults, repairs, sign-offs and photos', () => {
  const { ctx, sheets, post, oldSheets, driveFiles } = load();
  post({
    action: 'sync',
    push: {
      aircraft: [{ id: 'd24', updated_at: 't', deleted: 0, name: '24' }],
      people: [{ id: 'p-emil', updated_at: 't', deleted: 0, name: 'Emil Palla' }],
    },
    since: {},
  });
  driveFiles.push('a1.Visual Evidence.123.jpg');
  oldSheets.old = [
    ['Timestamp', 'Dron №/Bat', 'Severity Level', 'Description of Fault', 'Visual Evidence', 'Discovered By', 'Status',
      'Repair Start Date/Time:', 'Technician Name', 'Work Performed', 'Materials Used', 'Final Note', 'Authorized Signatory', 'Date'],
    ['8/15/2026 10:08:41 AM', '24', 'Class 2: Repair required', 'Prop tip splited', 'Fault_Images/a1.Visual Evidence.123.jpg',
      'Marcel', 'Not Fixed', '', '', '', '', '', '', ''],
    ['9/7/2026 7:35:00 AM', 'Dron 18', 'Class 1: Monitor only', 'Motor no 3 propeller small crack', '', 'Adam Kolowrocki',
      'Repaired', '9/7/2026 2:06:00 PM', 'Adam Kolowrocki', 'Damaged prop replaced', '1x CCW Propeller', '', 'Emil Palla', '9/7/2026 2:07:00 PM'],
    ['6/2/2026 10:49:57 AM', 'Radio Taranis', 'Class 3: Critical - UAS GROUNDED', 'broken switch SH', 'Fault_Images/gone.jpg',
      'Pavlo Yavorskyi', 'Fixed and Tested', '6/2/2026 7:30:10 PM', 'Pavlo Yavorskyi', 'switch replaced', 'switch',
      'Everything work fine', 'emil palla', '6/2/2026 8:35:52 PM'],
  ];
  oldSheets.old.push(['08/05/2026 15:53:41', 'Dron 24 bat 181 set 44 id3', 'Class 3: Critical - UAS GROUNDED.', 'Melted connectors', '',
    'Michal Pfeifer', 'Fixed and Tested', '09/05/2026 10:41:00', 'Adam Madziala', 'Connector replaced', 'Connector', 'Ok', 'Yavorskyi', '08/05/2026 15:53:00']);
  oldSheets.old.push(['', '', '', '', '', '', '', '', '', '', '', '', '', '']);
  assert.strictEqual(ctx.importOldFaults('old'), 4);
  const faults = rowsOf(sheets.faults);
  const prop = faults.find((f) => f.description === 'Prop tip splited');
  assert.strictEqual(prop.reported_at, '2026-08-15 10:08:41');
  assert.strictEqual(prop.aircraft_id, 'd24');
  assert.strictEqual(prop.severity, '2');
  assert.strictEqual(prop.discovered_by_id, 'Marcel');
  const radio = faults.find((f) => f.equipment === 'Radio Taranis');
  assert.strictEqual(radio.aircraft_id, '');
  assert.strictEqual(radio.severity, '3');
  // Drone 18 was missing and is added.
  assert.ok(rowsOf(sheets.aircraft).some((a) => a.name === '18'));
  const melted = faults.find((f) => f.description === 'Melted connectors');
  assert.strictEqual(melted.reported_at, '2026-05-08 15:53:41');
  assert.strictEqual(melted.aircraft_id, 'd24');
  assert.strictEqual(melted.equipment, 'Dron 24 bat 181 set 44 id3');
  const repairs = rowsOf(sheets.fault_repairs);
  assert.strictEqual(repairs.length, 3);
  assert.strictEqual(repairs.find((r) => r.fault_id === radio.id).started_at, '2026-06-02 19:30:10');
  const signoffs = rowsOf(sheets.fault_signoffs).filter((x) => x.fault_id !== melted.id);
  assert.strictEqual(signoffs.length, 1);
  assert.strictEqual(signoffs[0].fault_id, radio.id);
  assert.strictEqual(signoffs[0].result, 'pass');
  assert.strictEqual(signoffs[0].signatory_id, 'p-emil');
  assert.strictEqual(signoffs[0].tested_at, '2026-06-02 20:35:52');
  const photos = rowsOf(sheets.fault_photos);
  assert.deepStrictEqual(photos.map((p) => [p.fault_id, p.drive_file_id]), [[prop.id, 'drive-a1.Visual Evidence.123.jpg']]);
  // Running it again does not duplicate.
  ctx.importOldFaults('old');
  assert.strictEqual(sheets.faults.cells.length, 5);
});

test('timestamps: AppSheet month first with AM/PM, Sheets day first, ISO', () => {
  const { ctx } = load();
  assert.strictEqual(ctx.anyTimestamp_('12/1/2026 12:05:00 AM'), '2026-12-01 00:05:00');
  assert.strictEqual(ctx.anyTimestamp_('6/5/2026 12:30:00 PM'), '2026-06-05 12:30:00');
  assert.strictEqual(ctx.anyTimestamp_('14/03/2026 18:23'), '2026-03-14 18:23:00');
  assert.strictEqual(ctx.anyTimestamp_('2026-03-14T18:23:08'), '2026-03-14 18:23:08');
  assert.strictEqual(ctx.anyTimestamp_('soon'), '');
});

test('a photo is sent back only when fault_photos lists it', () => {
  const { post, pilot } = load();
  assert.strictEqual(pilot({ action: 'photo', drive_file_id: 'f1' }).ok, false);
  post({
    action: 'sync',
    push: { fault_photos: [{ id: 'ph1', updated_at: 't', deleted: 0, fault_id: 'x', drive_file_id: 'f1' }] },
    since: {},
  });
  const out = pilot({ action: 'photo', drive_file_id: 'f1' });
  assert.strictEqual(out.ok, true);
  assert.strictEqual(out.data, 'bytes-of-f1');
});

test('syncReleases copies a new release to Drive in pieces, over the old files', () => {
  const { ctx, props } = load();
  const sizes = { 'PilotLogbook-windows-v2.0.0.zip': 100, 'PilotLogbook-android-v2.0.0.apk': 40 * 1024 * 1024 };
  const calls = [];
  const res = (code, headers = {}, body = '') => ({
    getResponseCode: () => code,
    getAllHeaders: () => headers,
    getContentText: () => body,
    getContent: () => body,
  });
  let uploaded = 0;
  ctx.UrlFetchApp = {
    fetch(url, opt = {}) {
      calls.push([opt.method || 'get', url]);
      if (url.endsWith('/releases/latest')) return res(302, { Location: 'https://github.com/x/releases/tag/v2.0.0' });
      const asset = url.match(/releases\/download\/v2\.0\.0\/(.+)$/);
      if (asset) return sizes[asset[1]] ? res(302, { Location: 'https://cdn/' + asset[1] }) : res(404);
      if (url.startsWith('https://cdn/')) {
        const size = sizes[url.slice(12)];
        const [from, to] = opt.headers.Range.slice(6).split('-').map(Number);
        return res(206, { 'Content-Range': `bytes ${from}-${to}/${size}` }, 'x');
      }
      if (url.includes('uploadType=resumable')) return res(200, { Location: 'https://session/' + (++uploaded) });
      if (url.startsWith('https://session/')) {
        const [range, total] = opt.headers['Content-Range'].slice(6).split('/');
        const done = Number(range.split('-')[1]) + 1 === Number(total);
        return done ? res(200, {}, JSON.stringify({ id: 'drive-' + url.slice(16) })) : res(308);
      }
      throw new Error('unexpected ' + url);
    },
  };
  let readme = '';
  const folder = {
    getId: () => 'apps',
    isTrashed: () => false,
    getFilesByName: () => ({ hasNext: () => false }),
    createFile: (name, text) => (readme = text),
  };
  ctx.DriveApp.getFolderById = () => folder;
  ctx.DriveApp.getFileById = () => ({ isTrashed: () => false });
  ctx.MimeType = { PLAIN_TEXT: 'text/plain' };
  ctx.ScriptApp.getOAuthToken = () => 'tok';
  props.APPS_FOLDER_ID = 'apps';
  ctx.LockService.getScriptLock = () => ({ tryLock: () => true, releaseLock() {} });

  ctx.syncReleases();
  assert.strictEqual(props.APPS_VERSION, 'v2.0.0');
  assert.deepStrictEqual(JSON.parse(props.APPS_FILES), { windows: 'drive-1', android: 'drive-2' });
  // 40 MB goes in three 16 MB pieces.
  assert.strictEqual(calls.filter(([m, u]) => m === 'put' && u === 'https://session/2').length, 3);
  assert.match(readme, /PilotLogbook-android-v2\.0\.0\.apk/);
  assert.match(readme, /Maca jest w przygotowaniu/);

  // Same version again: nothing is fetched but the latest tag.
  calls.length = 0;
  ctx.syncReleases();
  assert.deepStrictEqual(calls, [['get', 'https://github.com/fpvsonderling/PilotLogbook/releases/latest']]);

  // The next release goes over the same Drive files (PATCH on their ids).
  props.APPS_VERSION = 'v1.9.0';
  calls.length = 0;
  ctx.syncReleases();
  assert.ok(calls.some(([m, u]) => m === 'patch' && u.includes('/files/drive-1?')));
});
