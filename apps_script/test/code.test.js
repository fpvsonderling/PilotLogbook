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
          : { getSheets: () => [{ getDataRange: () => ({ getDisplayValues: () => oldSheets[id] }) }] },
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
      newBlob: (data, type, name) => ({ data, type, name }),
    },
    Session: { getScriptTimeZone: () => 'UTC' },
    DriveApp: {
      getFoldersByName: () => ({ hasNext: () => false }),
      createFolder: (name) => ({
        createFile: (blob) => ({ getId: () => 'f-' + blob.name, getUrl: () => 'https://drive/' + blob.name }),
      }),
      getFileById: () => ({ makeCopy: (name) => files.push(name) }),
    },
    Logger: { log() {} },
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Code.gs'), 'utf8'), ctx);
  ctx.setup();
  const send = (token) => (body) =>
    JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token, ...body }) } }).text);
  // token-1 is the pilots' link, token-2 the admin link.
  return { ctx, sheets, props, files, post: send('token-2'), pilot: send('token-1'), oldSheets };
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
  assert.deepStrictEqual(sheets.flights.cells[0].slice(0, 5), ['id', 'updated_at', 'server_seq', 'deleted', 'date']);
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
