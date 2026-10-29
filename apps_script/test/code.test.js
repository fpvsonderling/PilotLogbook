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

function load({ standalone = false, fresh = false } = {}) {
  const sheets = {};
  const props = {};
  const files = [];
  if (standalone && !fresh) props.SPREADSHEET_ID = 'ss1';
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
      openById: (id) => (id === 'ss1' ? spreadsheet : null),
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
      getService: () => ({ getUrl: () => 'https://script.google.com/macros/s/abc/exec' }),
      getProjectTriggers: () => [],
      deleteTrigger() {},
      newTrigger: () => {
        const b = { timeBased: () => b, onMonthDay: () => b, atHour: () => b, create: () => b };
        return b;
      },
    },
    Utilities: {
      getUuid: () => 'token-1',
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
  const post = (body) =>
    JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token: 'token-1', ...body }) } }).text);
  return { ctx, sheets, props, files, post };
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

test('connectionLink gives the web app URL with the access token', () => {
  const { ctx } = load();
  assert.strictEqual(ctx.connectionLink(), 'https://script.google.com/macros/s/abc/exec?key=token-1');
});
