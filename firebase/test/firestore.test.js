// Security rules tests, run on the Firestore emulator: npm test
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment, assertFails, assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  doc, getDoc, setDoc, deleteDoc, collection, getDocs, query, where,
  serverTimestamp,
} = require('firebase/firestore');

let env;

const members = {
  master: { kind: 'master', active: true },
  shared: { kind: 'shared', active: true },
  sharedOff: { kind: 'shared', active: false },
  anna: { kind: 'person', person_id: 'p-anna', active: true },
  boss: { kind: 'person', person_id: 'p-boss', active: true },
  vera: { kind: 'person', person_id: 'p-vera', active: true },
  gone: { kind: 'person', person_id: 'p-gone', active: true },
};

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-pilotlogbook',
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
      host: '127.0.0.1',
      port: 8080,
    },
  });
});

test.after(async () => env && env.cleanup());

test.beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    for (const [uid, m] of Object.entries(members)) await setDoc(doc(db, 'members', uid), m);
    await setDoc(doc(db, 'people', 'p-anna'), { id: 'p-anna', name: 'Anna', roles: 'pilot', active: '1', deleted: '0' });
    await setDoc(doc(db, 'people', 'p-boss'), { id: 'p-boss', name: 'Boss', roles: 'pilot, admin', active: 1, deleted: 0 });
    await setDoc(doc(db, 'people', 'p-vera'), { id: 'p-vera', name: 'Vera', roles: 'viewer', active: 1, deleted: 0 });
    await setDoc(doc(db, 'people', 'p-gone'), { id: 'p-gone', name: 'Gone', roles: 'pilot', active: '0', deleted: '0' });
    await setDoc(doc(db, 'flights', 'f-anna'), { id: 'f-anna', updated_at: '2026-11-01T10:00:00.000Z', created_by: 'p-anna', deleted: 0, notes: 'a' });
    await setDoc(doc(db, 'flights', 'f-old'), { id: 'f-old', updated_at: '2026-10-01T10:00:00.000Z', created_by: '', deleted: '0', notes: 'old' });
    await setDoc(doc(db, 'competencies', 'c-anna'), { id: 'c-anna', person_id: 'p-anna', updated_at: '2026-11-01T10:00:00.000Z', created_by: 'p-anna', verified: 1 });
    await setDoc(doc(db, 'competencies', 'c-boss'), { id: 'c-boss', person_id: 'p-boss', updated_at: '2026-11-01T10:00:00.000Z', created_by: 'p-boss' });
  });
});

const db = (uid) => env.authenticatedContext(uid).firestore();

function row(id, extra) {
  return { id, updated_at: '2026-11-05T10:00:00.000Z', server_time: serverTimestamp(), deleted: 0, ...extra };
}

test('no key, unknown key and turned off keys read nothing', async () => {
  await assertFails(getDoc(doc(env.unauthenticatedContext().firestore(), 'flights', 'f-anna')));
  await assertFails(getDoc(doc(db('stranger'), 'flights', 'f-anna')));
  await assertFails(getDoc(doc(db('sharedOff'), 'flights', 'f-anna')));
  // A person not active in People.
  await assertFails(getDoc(doc(db('gone'), 'flights', 'f-anna')));
  await assertSucceeds(getDoc(doc(db('anna'), 'flights', 'f-anna')));
});

test('everyone reads their own member document only', async () => {
  await assertSucceeds(getDoc(doc(db('anna'), 'members', 'anna')));
  await assertFails(getDoc(doc(db('anna'), 'members', 'boss')));
  await assertSucceeds(getDocs(collection(db('boss'), 'members')));
  await assertFails(getDocs(collection(db('anna'), 'members')));
  await assertFails(setDoc(doc(db('anna'), 'members', 'anna2'), { kind: 'master', active: true }));
  await assertSucceeds(setDoc(doc(db('master'), 'members', 'new'), { kind: 'person', person_id: 'p-anna', active: true }));
});

test('a pilot adds rows as their own and changes only those', async () => {
  await assertSucceeds(setDoc(doc(db('anna'), 'flights', 'f-new'), row('f-new', { created_by: 'p-anna' })));
  // Not as someone else, not without the server time.
  await assertFails(setDoc(doc(db('anna'), 'flights', 'f-x'), row('f-x', { created_by: 'p-boss' })));
  await assertFails(setDoc(doc(db('anna'), 'flights', 'f-y'), { ...row('f-y', { created_by: 'p-anna' }), server_time: new Date() }));
  // The id field is the document id.
  await assertFails(setDoc(doc(db('anna'), 'flights', 'f-z'), row('other', { created_by: 'p-anna' })));
  await assertSucceeds(setDoc(doc(db('anna'), 'flights', 'f-anna'), row('f-anna', { created_by: 'p-anna', notes: 'b' })));
  await assertSucceeds(setDoc(doc(db('anna'), 'flights', 'f-anna'), row('f-anna', { created_by: 'p-anna', deleted: 1 })));
  await assertFails(setDoc(doc(db('anna'), 'flights', 'f-old'), row('f-old', { created_by: 'p-anna' })));
  await assertFails(deleteDoc(doc(db('anna'), 'flights', 'f-anna')));
});

test('an older edit loses to the stored one', async () => {
  await assertFails(setDoc(doc(db('anna'), 'flights', 'f-anna'), { ...row('f-anna', { created_by: 'p-anna' }), updated_at: '2026-10-01T00:00:00.000Z' }));
  await assertFails(setDoc(doc(db('master'), 'flights', 'f-anna'), { ...row('f-anna'), updated_at: '2026-10-01T00:00:00.000Z' }));
});

test('the shared key only adds', async () => {
  await assertSucceeds(setDoc(doc(db('shared'), 'flights', 'f-s'), row('f-s')));
  await assertSucceeds(setDoc(doc(db('shared'), 'flights', 'f-s2'), row('f-s2', { created_by: '' })));
  await assertFails(setDoc(doc(db('shared'), 'flights', 'f-s3'), row('f-s3', { deleted: 1 })));
  await assertFails(setDoc(doc(db('shared'), 'flights', 'f-old'), row('f-old', { created_by: '' })));
  await assertFails(setDoc(doc(db('sharedOff'), 'flights', 'f-s4'), row('f-s4')));
});

test('admins change everything, viewers nothing', async () => {
  for (const uid of ['master', 'boss']) {
    await assertSucceeds(setDoc(doc(db(uid), 'flights', 'f-old'), row('f-old', { created_by: '', notes: uid })));
    await assertSucceeds(setDoc(doc(db(uid), 'documents', 'd-' + uid), row('d-' + uid)));
    await assertSucceeds(setDoc(doc(db(uid), 'people', 'p-anna'), row('p-anna', { roles: 'pilot', active: 1 })));
  }
  await assertSucceeds(getDoc(doc(db('vera'), 'flights', 'f-anna')));
  await assertFails(setDoc(doc(db('vera'), 'flights', 'f-v'), row('f-v', { created_by: 'p-vera' })));
  await assertFails(setDoc(doc(db('vera'), 'meta', 'changes'), { flights: serverTimestamp() }));
});

test('only the admin adds documents, projects and intervals', async () => {
  for (const t of ['documents', 'projects', 'maintenance_intervals']) {
    await assertFails(setDoc(doc(db('anna'), t, 'x'), row('x', { created_by: 'p-anna' })));
    await assertFails(setDoc(doc(db('shared'), t, 'x'), row('x')));
  }
});

test('notification settings and phones: own rows only', async () => {
  for (const table of ['notify_settings', 'push_devices']) {
    await assertSucceeds(setDoc(doc(db('anna'), table, 'n-anna'), row('n-anna', { person_id: 'p-anna', created_by: 'p-anna' })));
    await assertFails(setDoc(doc(db('anna'), table, 'n-boss'), row('n-boss', { person_id: 'p-boss' })));
    await assertSucceeds(getDocs(query(collection(db('anna'), table), where('person_id', '==', 'p-anna'))));
    await assertFails(getDocs(collection(db('anna'), table)));
    await assertSucceeds(getDocs(collection(db('boss'), table)));
    await assertSucceeds(setDoc(doc(db('boss'), table, 'n-master'), row('n-master', { person_id: 'master' })));
  }
});

test('competencies: own rows only, verified only by the admin', async () => {
  await assertSucceeds(getDoc(doc(db('anna'), 'competencies', 'c-anna')));
  await assertFails(getDoc(doc(db('anna'), 'competencies', 'c-boss')));
  await assertSucceeds(getDocs(query(collection(db('anna'), 'competencies'), where('person_id', '==', 'p-anna'))));
  await assertFails(getDocs(collection(db('anna'), 'competencies')));
  await assertSucceeds(getDocs(collection(db('boss'), 'competencies')));
  await assertSucceeds(setDoc(doc(db('anna'), 'competencies', 'c-anna'), row('c-anna', { person_id: 'p-anna', created_by: 'p-anna', verified: null, verified_by: '' })));
  await assertFails(setDoc(doc(db('anna'), 'competencies', 'c-anna2'), row('c-anna2', { person_id: 'p-anna', verified: 1 })));
  await assertFails(setDoc(doc(db('anna'), 'competencies', 'c-x'), row('c-x', { person_id: 'p-boss' })));
  await assertFails(setDoc(doc(db('anna'), 'competencies', 'c-boss'), row('c-boss', { person_id: 'p-anna' })));
  await assertSucceeds(setDoc(doc(db('boss'), 'competencies', 'c-anna'), row('c-anna', { person_id: 'p-anna', verified: 1, verified_by: 'p-boss' })));
});

test('meta/changes is written by every key that may write', async () => {
  await assertSucceeds(setDoc(doc(db('anna'), 'meta', 'changes'), { flights: serverTimestamp() }, { merge: true }));
  await assertSucceeds(getDoc(doc(db('vera'), 'meta', 'changes')));
  await assertFails(setDoc(doc(db('master'), 'meta', 'config'), { bucket: 'x' }));
  await assertFails(setDoc(doc(db('anna'), 'secrets', 'x'), row('x', { created_by: 'p-anna' })));
});
