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
  // Drive files the documents tests use: id -> { name, mime, bytes, updated }.
  const docs = {};
  const fetches = [];
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
      getOAuthToken: () => 'oauth',
      deleteTrigger() {},
      newTrigger: () => {
        const b = { timeBased: () => b, onMonthDay: () => b, atHour: () => b, everyHours: () => b, create: () => b };
        return b;
      },
    },
    Utilities: {
      getUuid: () => 'token-' + ++uuid,
      formatDate: () => '2026-11',
      base64Decode: (s) => s,
      base64Encode: (s) => s,
      Charset: { UTF_8: 'utf8' },
      base64EncodeWebSafe: (s) => Buffer.from(s, 'utf8').toString('base64url') + '==',
      newBlob: (data, type, name) => ({ data, type, name }),
    },
    Session: { getScriptTimeZone: () => 'UTC' },
    DriveApp: {
      getFoldersByName: () => ({ hasNext: () => false }),
      createFolder: (name) => ({
        getId: () => 'folder-' + name,
        createFile: (blob) => ({ getId: () => 'f-' + blob.name, getUrl: () => 'https://drive/' + blob.name }),
      }),
      getFileById: (id) => {
        const d = docs[id];
        if (d) {
          return {
            getName: () => d.name,
            getMimeType: () => d.mime,
            getSize: () => d.bytes.length,
            getLastUpdated: () => new Date(d.updated),
            getUrl: () => 'https://drive/' + id,
            getAs: () => ({ getBytes: () => Array.from(Buffer.from('pdf-of-' + d.name)) }),
          };
        }
        if (id.startsWith('missing')) throw new Error('No item with the given ID');
        return {
        makeCopy: (name) => files.push(name),
        getBlob: () => ({ getContentType: () => 'image/jpeg', getBytes: () => 'bytes-of-' + id }),
        };
      },
      getFilesByName: (name) => {
        const found = driveFiles.includes(name);
        return { hasNext: () => found, next: () => ({ getId: () => 'drive-' + name, getUrl: () => 'https://drive/' + name }) };
      },
    },
    Logger: { log() {} },
    UrlFetchApp: {
      fetch: (url, opts) => {
        fetches.push({ url, opts });
        if (url.includes('/upload/drive/')) {
          return { getResponseCode: () => 200, getAllHeaders: () => ({ Location: 'https://upload/session-1' }) };
        }
        const id = decodeURIComponent(url.split('/files/')[1].split('?')[0]);
        const [a, b] = opts.headers.Range.replace('bytes=', '').split('-').map(Number);
        return { getResponseCode: () => 206, getContent: () => docs[id].bytes.slice(a, b + 1) };
      },
    },
    Buffer,
  };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Code.gs'), 'utf8'), ctx);
  ctx.setup();
  const send = (token) => (body) =>
    JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token, ...body }) } }).text);
  // token-1 is the pilots' link, token-2 the admin link.
  return { ctx, sheets, props, files, post: send('token-2'), pilot: send('token-1'), oldSheets, driveFiles, docs, fetches };
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
  post({ action: 'sync', push: { people: [{ id: 'p-anna', updated_at: 't0', deleted: 0, name: 'Anna', roles: 'pilot', active: 1 }] }, since: {} });
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

const decodeKey = (key) => {
  assert.match(key, /^PL1-[A-Za-z0-9_-]+$/);
  return Buffer.from(key.slice(4), 'base64url').toString('utf8');
};

test('connectionLink gives an access key: web app id and token, no URL', () => {
  const { ctx } = load();
  const key = ctx.connectionLink();
  assert.ok(!key.includes('script.google.com'));
  assert.strictEqual(decodeKey(key), 'abc token-1');
});

test('connectionLink uses the deployed /exec id when run from the editor', () => {
  const { ctx } = load({ serviceUrl: 'https://script.google.com/macros/s/abc/dev' });
  assert.strictEqual(decodeKey(ctx.connectionLink()), 'abc token-1');
});

test('an unusual web app URL goes into the key whole', () => {
  const { ctx } = load({ serviceUrl: 'https://script.google.com/a/macros/firm.pl/s/abc/exec' });
  assert.strictEqual(decodeKey(ctx.connectionLink()), 'https://script.google.com/a/macros/firm.pl/s/abc/exec token-1');
});

const person = (id, extra = {}) => ({ id, updated_at: 't0', server_seq: null, deleted: 0, name: id, roles: 'pilot', active: 1, ...extra });

function withPerson(roles, extra = {}) {
  const loaded = load();
  loaded.post({ action: 'sync', push: { people: [person('p-anna', { roles, ...extra })] }, since: {} });
  const link = loaded.post({ action: 'personLink', person_id: 'p-anna' });
  const anna = (body) =>
    JSON.parse(loaded.ctx.doPost({ postData: { contents: JSON.stringify({ token: link.token, ...body }) } }).text);
  return { ...loaded, link, anna };
}

test('personLink answers with the person\'s access key', () => {
  const { link } = withPerson('pilot');
  assert.strictEqual(decodeKey(link.key), 'abc ' + link.token);
});

test('a viewer key reads everything but changes and adds nothing', () => {
  const { anna, post, sheets } = withPerson('pilot,viewer');
  post({ action: 'sync', push: { flights: [flight('a', 't1', { notes: 'x' })] }, since: {} });
  const out = anna({
    action: 'sync',
    push: { flights: [flight('a', 't2', { notes: 'y' }), flight('new', 't2')] },
    since: { flights: 0 },
  });
  assert.strictEqual(out.ok, true);
  assert.strictEqual(out.readOnly, true);
  assert.strictEqual(out.admin, false);
  assert.deepStrictEqual(out.accepted.flights, []);
  assert.deepStrictEqual(out.denied.flights, ['a', 'new']);
  assert.strictEqual(out.pulled.flights.length, 1);
  assert.strictEqual(out.pulled.flights[0].notes, 'x');
  assert.strictEqual(sheets.flights.cells.length, 2);
  assert.strictEqual(anna({ action: 'uploadPhoto', name: 'x.jpg', data: 'abc' }).ok, false);
});

test('a person with the admin role gets admin rights with their own key', () => {
  const { anna, post } = withPerson('pilot,admin');
  post({ action: 'sync', push: { flights: [flight('b', 't1', { created_by: 'p-bob' })] }, since: {} });
  const out = anna({ action: 'sync', push: { flights: [flight('b', 't2', { deleted: 1 }), flight('c', 't2')] }, since: {} });
  assert.strictEqual(out.admin, true);
  assert.deepStrictEqual(out.accepted.flights.map((r) => r.id), ['b', 'c']);
  // A row the admin adds is still marked as theirs.
  assert.strictEqual(out.pulled.flights.find((r) => r.id === 'c').created_by, 'p-anna');
  assert.strictEqual(anna({ action: 'personLink', person_id: 'p-bob' }).ok, true);
});

test('a person\'s key stops working when they are made inactive or deleted', () => {
  const { anna, post } = withPerson('pilot');
  assert.strictEqual(anna({ action: 'sync', push: {}, since: {} }).ok, true);
  post({ action: 'sync', push: { people: [person('p-anna', { updated_at: 't1', active: 0 })] }, since: {} });
  assert.strictEqual(anna({ action: 'sync', push: {}, since: {} }).ok, false);
  post({ action: 'sync', push: { people: [person('p-anna', { updated_at: 't2', active: 1 })] }, since: {} });
  assert.strictEqual(anna({ action: 'sync', push: {}, since: {} }).ok, true);
  post({ action: 'sync', push: { people: [person('p-anna', { updated_at: 't3', deleted: 1 })] }, since: {} });
  assert.strictEqual(anna({ action: 'sync', push: {}, since: {} }).ok, false);
});

test('a key for someone not in People does not work', () => {
  const { post, ctx } = load();
  const link = post({ action: 'personLink', person_id: 'p-ghost' });
  const out = JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token: link.token, action: 'sync' }) } }).text);
  assert.strictEqual(out.ok, false);
});

test('renew makes a new key and turns the old one off', () => {
  const { anna, post, link, ctx } = withPerson('pilot');
  const fresh = post({ action: 'personLink', person_id: 'p-anna', renew: true });
  assert.notStrictEqual(fresh.token, link.token);
  assert.strictEqual(anna({ action: 'sync', push: {}, since: {} }).ok, false);
  const out = JSON.parse(ctx.doPost({ postData: { contents: JSON.stringify({ token: fresh.token, action: 'sync', push: {}, since: {} }) } }).text);
  assert.strictEqual(out.ok, true);
  assert.strictEqual(out.me, 'p-anna');
});

test('disableSharedKey turns the shared pilots\' key off', () => {
  const { ctx, pilot, post } = load();
  assert.strictEqual(pilot({ action: 'sync', push: {}, since: {} }).ok, true);
  ctx.disableSharedKey();
  assert.strictEqual(pilot({ action: 'sync', push: {}, since: {} }).ok, false);
  assert.strictEqual(post({ action: 'sync', push: {}, since: {} }).ok, true);
  assert.strictEqual(decodeKey(ctx.connectionLink()), 'abc token-2');
  ctx.enableSharedKey();
  assert.strictEqual(pilot({ action: 'sync', push: {}, since: {} }).ok, true);
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

test('old AppSheet maintenance rows become maintenance rows', () => {
  const { ctx, sheets, post, oldSheets } = load();
  post({ action: 'sync', push: { aircraft: [{ id: 'd18', updated_at: 't', deleted: 0, name: '18' }] }, since: {} });
  oldSheets['1pLX_T4Vdv_4bP-69eEmOdRy2OjZrFRSuHPInY9CEbtA'] = [
    ['Timestamp', '*ID', 'Dron number', 'Arm Assembly ', 'Center Plate ', 'Propulsion System', ' Load Assembly', 'Leg Assembly', 'Power System ', 'FTS'],
    ['25/03/2026 19:21:00', '1', '24', 'Checked', 'Checked', 'Checked', 'Checked', 'Checked', 'Checked', ''],
    ['07/08/2026 10:48:45', '4', '18', 'Replaced 3 propellers.', '', '', '', '', 'Fixed gcs charging issue', ''],
    ['', '', '', '', '', '', '', '', '', ''],
  ];
  assert.strictEqual(ctx.importOldMaintenance(), 2);
  const rows = rowsOf(sheets.maintenance);
  const a = rows.find((r) => r.id === 'import-maintenance-4');
  assert.strictEqual(a.performed_at, '2026-08-07 10:48:45');
  assert.strictEqual(a.aircraft_id, 'd18');
  assert.strictEqual(a.arm_assembly, 'Replaced 3 propellers.');
  assert.strictEqual(a.power_system, 'Fixed gcs charging issue');
  assert.strictEqual(a.center_plate, '');
  const b = rows.find((r) => r.id === 'import-maintenance-1');
  assert.strictEqual(b.performed_at, '2026-03-25 19:21:00');
  assert.strictEqual(b.leg_assembly, 'Checked');
  // Drone 24 was missing and is added.
  assert.ok(sheets.aircraft.cells.some((r) => r.includes('24')));
  ctx.importOldMaintenance();
  assert.strictEqual(sheets.maintenance.cells.length, 3);
});

test('Inspection LogBook rows become inspection flights; drones get their usage', () => {
  const { ctx, sheets, post, oldSheets } = load();
  post({ action: 'sync', push: {
    aircraft: [{ id: 'd18', updated_at: '2026-10-30T10:00:00.000Z', deleted: 0, name: '18', active: 1 }],
    people: [{ id: 'p-marcel', updated_at: 't', deleted: 0, name: 'Marcel Jaworski', roles: 'pilot', active: 1 }],
  }, since: {} });
  oldSheets['1lvmAEMN34PAOrhTQ4FVdwH2R-I6y8jvoy0JpCZ72fSw'] = [
    ['id', 'Date', 'Project', 'Dron №', 'TakeOff', 'Land', 'Time', 'RP', 'PA', 'NOTES'],
    ['1', '08/10/2026', 'Dogger Bank', ' Matrice 30T', '03:14:15', '03:25:00', '00:10:45', 'Marcel Jaworski', 'Andy Grimes', 'T05 TEST'],
    ['3', '12.10.2026', 'Dogger Bank', 'Matrice 30T', '14:47:03', '14:47:05', '00:00:02', 'Andy Grimes', 'Marcel Jaworski', 'Test'],
    ['', '', '', '', '', '', '00:00:00', '', '', ''],
  ];
  assert.strictEqual(ctx.importInspectionLogbook(), 2);
  const flights = rowsOf(sheets.flights);
  const a = flights.find((r) => r.id === 'import-inspection-1');
  assert.strictEqual(a.kind, 'inspection');
  assert.strictEqual(a.date, '2026-10-08');
  assert.strictEqual(a.duration_s, '645');
  assert.strictEqual(a.rp_id, 'p-marcel');
  assert.strictEqual(a.notes, 'T05 TEST');
  assert.strictEqual(flights.find((r) => r.id === 'import-inspection-3').date, '2026-10-12');
  const drones = rowsOf(sheets.aircraft);
  const m30 = drones.find((r) => r.name === 'Matrice 30T');
  assert.strictEqual(m30.usage, 'inspection');
  assert.strictEqual(a.aircraft_id, m30.id);
  assert.strictEqual(drones.find((r) => r.id === 'd18').usage, 'cargo');
  assert.strictEqual(drones.find((r) => r.id === 'd18').name, '18');
  const andy = rowsOf(sheets.people).find((r) => r.name === 'Andy Grimes');
  assert.strictEqual(a.pa_id, andy.id);
  assert.strictEqual(rowsOf(sheets.projects).length, 1);
  // A rerun adds nothing new.
  ctx.importInspectionLogbook();
  assert.strictEqual(rowsOf(sheets.flights).length, 2);
  assert.strictEqual(rowsOf(sheets.aircraft).length, 2);
  assert.strictEqual(rowsOf(sheets.people).length, 2);
});

const doc = (id, updatedAt, extra = {}) => ({
  id,
  updated_at: updatedAt,
  server_seq: null,
  deleted: 0,
  title: 'Operations Manual',
  drive_file_id: 'd1',
  ...extra,
});

test('only the admin link adds, changes and deletes documents', () => {
  const { post, pilot } = load();
  const p = pilot({ action: 'sync', push: { documents: [doc('doc1', '2026-11-02T10:00:00Z')] }, since: {} });
  assert.deepStrictEqual(p.denied.documents, ['doc1']);
  assert.strictEqual(p.accepted.documents.length, 0);
  const a = post({ action: 'sync', push: { documents: [doc('doc1', '2026-11-02T10:00:00Z')] }, since: {} });
  assert.strictEqual(a.accepted.documents.length, 1);
  const del = pilot({ action: 'sync', push: { documents: [doc('doc1', '2026-11-02T11:00:00Z', { deleted: 1 })] }, since: { documents: 99 } });
  assert.deepStrictEqual(del.denied.documents, ['doc1']);
  assert.strictEqual(del.pulled.documents[0].deleted, '0');
  assert.strictEqual(pilot({ action: 'documentUpload', name: 'a.pdf', size: 3 }).ok, false);
  assert.strictEqual(pilot({ action: 'documentInfo', drive_file_id: 'd1' }).ok, false);
});

test('the admin starts a document upload into the documents folder', () => {
  const { post, fetches } = load();
  const r = post({ action: 'documentUpload', name: 'OM.pdf', mimeType: 'application/pdf', size: 1234 });
  assert.strictEqual(r.upload_url, 'https://upload/session-1');
  const body = JSON.parse(fetches[0].opts.payload);
  assert.deepStrictEqual(body.parents, ['folder-PilotLogbook Documents']);
  assert.strictEqual(fetches[0].opts.headers['X-Upload-Content-Length'], '1234');
});

test('document info: Drive files as they are, Google Docs as PDF', () => {
  const { post, docs } = load();
  docs.d1 = { name: 'OM.pdf', mime: 'application/pdf', bytes: [1, 2, 3], updated: '2026-11-01T08:00:00Z' };
  docs.g1 = { name: 'Checklist', mime: 'application/vnd.google-apps.document', bytes: [], updated: '2026-11-01T09:00:00Z' };
  const a = post({ action: 'documentInfo', drive_file_id: 'd1' });
  assert.deepStrictEqual(
    [a.file_name, a.mime_type, a.size_bytes, a.file_version],
    ['OM.pdf', 'application/pdf', '3', '2026-11-01T08:00:00.000Z'],
  );
  const g = post({ action: 'documentInfo', drive_file_id: 'g1' });
  assert.deepStrictEqual([g.file_name, g.mime_type], ['Checklist.pdf', 'application/pdf']);
  assert.strictEqual(post({ action: 'documentInfo', drive_file_id: 'missing1' }).ok, false);
});

test('a document is sent in pieces, only when the documents tab lists it', () => {
  const { post, pilot, docs } = load();
  const bytes = Array.from({ length: 20 }, (_, i) => i);
  docs.d1 = { name: 'OM.pdf', mime: 'application/pdf', bytes, updated: '2026-11-01T08:00:00Z' };
  assert.strictEqual(pilot({ action: 'documentPart', drive_file_id: 'd1', offset: 0 }).ok, false);
  post({ action: 'sync', push: { documents: [doc('doc1', '2026-11-02T10:00:00Z')] }, since: {} });
  const first = pilot({ action: 'documentPart', drive_file_id: 'd1', offset: 0 });
  assert.strictEqual(first.size, 20);
  assert.strictEqual(first.version, '2026-11-01T08:00:00.000Z');
  assert.deepStrictEqual(first.data, bytes);
  const piece = pilot({ action: 'documentPart', drive_file_id: 'd1', offset: 8, length: 8 });
  assert.deepStrictEqual(piece.data, bytes.slice(8, 16));
  const end = pilot({ action: 'documentPart', drive_file_id: 'd1', offset: 20 });
  assert.deepStrictEqual(end.data, '');
  post({ action: 'sync', push: { documents: [doc('doc1', '2026-11-02T11:00:00Z', { deleted: 1 })] }, since: {} });
  assert.strictEqual(pilot({ action: 'documentPart', drive_file_id: 'd1', offset: 0 }).ok, false);
});

test('refreshDocuments gives a document changed in Drive its new version', () => {
  const { ctx, post, docs } = load();
  docs.d1 = { name: 'OM.pdf', mime: 'application/pdf', bytes: [1, 2], updated: '2026-11-01T08:00:00Z' };
  post({ action: 'sync', push: { documents: [doc('doc1', '2026-11-02T10:00:00Z', { file_version: '2026-11-01T08:00:00.000Z' })] }, since: {} });
  assert.strictEqual(ctx.refreshDocuments(), 0);
  docs.d1 = { name: 'OM.pdf', mime: 'application/pdf', bytes: [1, 2, 3, 4], updated: '2026-11-02T12:00:00Z' };
  assert.strictEqual(ctx.refreshDocuments(), 1);
  const r = post({ action: 'sync', push: {}, since: { documents: 1 } });
  assert.strictEqual(r.pulled.documents.length, 1);
  assert.deepStrictEqual(
    [r.pulled.documents[0].file_version, r.pulled.documents[0].size_bytes],
    ['2026-11-02T12:00:00.000Z', '4'],
  );
});

const comp = (id, updated_at, extra = {}) => ({ id, updated_at, server_seq: null, deleted: 0, person_id: 'p-anna', type: 'GWO', expires_on: '2027-01-01', ...extra });

test('competencies: each person gets and changes only their own; only the admin verifies', () => {
  const { anna, post, pilot, sheets } = withPerson('pilot');
  // The admin adds one for Anna and one for Bob, both verified.
  post({
    action: 'sync',
    push: { competencies: [comp('c-anna', 't1', { verified: 1 }), comp('c-bob', 't1', { person_id: 'p-bob', verified: 1 })] },
    since: {},
  });
  const mine = anna({ action: 'sync', push: {}, since: { competencies: 0 } });
  assert.deepStrictEqual(mine.pulled.competencies.map((r) => r.id), ['c-anna']);
  // The shared pilots' key gets none.
  assert.deepStrictEqual(pilot({ action: 'sync', push: {}, since: { competencies: 0 } }).pulled.competencies, []);
  // The admin gets all.
  assert.strictEqual(post({ action: 'sync', push: {}, since: { competencies: 0 } }).pulled.competencies.length, 2);

  const out = anna({
    action: 'sync',
    push: {
      competencies: [
        comp('c-anna', 't2', { number: '123', verified: 1 }), // own, made by the admin
        comp('c-bob', 't2', { person_id: 'p-bob' }), // someone else's
        comp('c-steal', 't2', { person_id: 'p-anna' }), // new, own
        comp('c-other', 't2', { person_id: 'p-bob' }), // new, for someone else
      ],
    },
    since: { competencies: 3 },
  });
  assert.deepStrictEqual(out.accepted.competencies.map((r) => r.id), ['c-anna', 'c-steal']);
  assert.deepStrictEqual(out.denied.competencies, ['c-bob', 'c-other']);
  // Bob's row is not sent back to Anna even though her edit was refused.
  assert.deepStrictEqual(out.pulled.competencies.map((r) => r.id).sort(), ['c-anna', 'c-steal']);
  const h = sheets.competencies.cells[0];
  const row = (id) => sheets.competencies.cells.find((r) => r[0] === id);
  assert.strictEqual(row('c-anna')[h.indexOf('number')], '123');
  // Her change takes the verified mark off.
  assert.strictEqual(row('c-anna')[h.indexOf('verified')], '');
  assert.strictEqual(row('c-bob')[h.indexOf('verified')], '1');
  // A row moved to Bob is refused too.
  const move = anna({ action: 'sync', push: { competencies: [comp('c-steal', 't3', { person_id: 'p-bob' })] }, since: {} });
  assert.deepStrictEqual(move.denied.competencies, ['c-steal']);
  // She deletes her own.
  anna({ action: 'sync', push: { competencies: [comp('c-steal', 't4', { deleted: 1 })] }, since: {} });
  assert.strictEqual(row('c-steal')[h.indexOf('deleted')], '1');
});

test('only the admin changes maintenance intervals', () => {
  const { post, pilot } = load();
  const iv = { id: 'i1', updated_at: 't1', deleted: 0, model: '', section: 'fts', days: '30' };
  assert.deepStrictEqual(pilot({ action: 'sync', push: { maintenance_intervals: [iv] }, since: {} }).denied.maintenance_intervals, ['i1']);
  assert.strictEqual(post({ action: 'sync', push: { maintenance_intervals: [iv] }, since: {} }).accepted.maintenance_intervals.length, 1);
});
