// Sync with Firebase against the local emulators and the real security
// rules (firebase/firestore.rules, firebase/storage.rules). Skipped unless
// FIREBASE_EMULATORS is set; run from the repository root:
//   cd firebase && npx firebase emulators:exec --only auth,firestore,storage \
//     'cd ../app && FIREBASE_EMULATORS=1 flutter test test/firebase_emulator_test.dart'
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pilot_logbook/data/documents.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/photos.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/firebase_client.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';

const project = 'demo-pilotlogbook';
const hosts = FirebaseHosts.emulator();
const base = FirebaseKey(
  projectId: project,
  apiKey: 'fake-api-key',
  id: '',
  secret: '',
);

final _owner = {
  'Authorization': 'Bearer owner',
  'Content-Type': 'application/json',
};
const _docs = 'v1/projects/$project/databases/(default)/documents';

/// Writes a document past the rules, as the migration script does.
Future<void> seed(String path, Map<String, Object?> fields) async {
  final res = await http.patch(
    Uri.parse('${hosts.firestore}/$_docs/$path'),
    headers: _owner,
    body: jsonEncode({'fields': FirebaseClient.encodeFields(fields)}),
  );
  expect(res.statusCode, 200, reason: res.body);
}

Future<void> seedRows(String table, List<Map<String, Object?>> rows) async {
  final writes = [
    for (final r in rows)
      {
        'update': {
          'name':
              'projects/$project/databases/(default)/documents/$table/${r['id']}',
          'fields': FirebaseClient.encodeFields(r),
        },
        'updateTransforms': [
          {'fieldPath': 'server_time', 'setToServerValue': 'REQUEST_TIME'},
        ],
      },
    {
      'update': {
        'name': 'projects/$project/databases/(default)/documents/meta/changes',
        'fields': {},
      },
      'updateMask': {'fieldPaths': []},
      'updateTransforms': [
        {'fieldPath': table, 'setToServerValue': 'REQUEST_TIME'},
      ],
    },
  ];
  final res = await http.post(
    Uri.parse('${hosts.firestore}/$_docs:commit'),
    headers: _owner,
    body: jsonEncode({'writes': writes}),
  );
  expect(res.statusCode, 200, reason: res.body);
}

/// A new key whose Auth account exists, with its member document.
Future<FirebaseKey> makeKey(Map<String, Object?> member) async {
  final key = base.fresh();
  final uid = await FirebaseClient(key, hosts: hosts).createAccount(key);
  await seed('members/$uid', {'uid': uid, ...member, 'key': key.encode()});
  return key;
}

SyncService device(FirebaseKey key, {String? files}) {
  final dir = files ?? Directory.systemTemp.createTempSync('pl').path;
  final sync = SyncService(
    LocalDb.inMemory(),
    photos: PhotoStore('$dir/photos'),
    documents: DocumentStore('$dir/documents'),
  )..firebaseFactory = (k) => FirebaseClient(k, hosts: hosts);
  expect(sync.setAccessKey(key.encode()), isTrue);
  return sync;
}

Future<void> synced(SyncService s) async {
  final r = await s.sync();
  expect(s.lastError, isNull);
  expect(r, isNotNull);
}

void main() {
  final run = Platform.environment['FIREBASE_EMULATORS'] != null;

  late FirebaseKey master, anna, vera, shared;

  test('keys survive the access key text', () {
    final k = base.fresh();
    final back = FirebaseKey.decode(k.encode())!;
    expect(back.encode(), k.encode());
    expect(back.email, k.email);
    expect(FirebaseKey.decode('PL1-abc'), isNull);
  });

  group('emulator', skip: run ? false : 'FIREBASE_EMULATORS not set', () {
    setUp(() async {
      await http.delete(
        Uri.parse(
          '${hosts.firestore}/emulator/v1/projects/$project/databases/(default)/documents',
        ),
      );
      await http.delete(
        Uri.parse(
          '${hosts.auth.replaceFirst('/identitytoolkit.googleapis.com', '')}/emulator/v1/projects/$project/accounts',
        ),
      );
      await seedRows('people', [
        {
          'id': 'p-anna',
          'updated_at': '2026-11-01T00:00:00Z',
          'name': 'Anna',
          'roles': 'pilot',
          'active': '1',
          'deleted': '0',
        },
        {
          'id': 'p-boss',
          'updated_at': '2026-11-01T00:00:00Z',
          'name': 'Boss',
          'roles': 'pilot, admin',
          'active': '1',
          'deleted': '0',
        },
        {
          'id': 'p-vera',
          'updated_at': '2026-11-01T00:00:00Z',
          'name': 'Vera',
          'roles': 'viewer',
          'active': '1',
          'deleted': '0',
        },
      ]);
      master = await makeKey({'kind': 'master', 'active': true});
      anna = await makeKey({
        'kind': 'person',
        'person_id': 'p-anna',
        'active': true,
      });
      vera = await makeKey({
        'kind': 'person',
        'person_id': 'p-vera',
        'active': true,
      });
      shared = await makeKey({'kind': 'shared', 'active': true});
    });

    test('rows go up from one device and down to another', () async {
      final a = device(anna);
      final boss = device(master);
      final id = a.db.save(Tables.flights, {
        'date': '2026-11-08',
        'kind': 'cargo',
        'duration_s': 600,
        'used': 12.5,
      });
      await synced(a);
      expect(a.pendingCount, 0);
      expect(a.isAdmin, isFalse);
      expect(a.me, 'p-anna');
      await synced(boss);
      expect(boss.isAdmin, isTrue);
      final got = boss.db.byId(Tables.flights, id)!;
      expect(got['created_by'], 'p-anna');
      expect(got['duration_s'], 600);
      expect(got['used'], 12.5);
      expect(boss.db.rows(Tables.people), hasLength(3));

      // The admin changes Anna's flight; Anna gets it.
      boss.db.save(Tables.flights, {'id': id, 'notes': 'checked'});
      await synced(boss);
      await synced(a);
      expect(a.db.byId(Tables.flights, id)!['notes'], 'checked');
      expect(a.canChange(a.db.byId(Tables.flights, id)!), isTrue);
    });

    test('an edit the rules refuse is undone on the device', () async {
      await seedRows('flights', [
        {
          'id': 'f-boss',
          'updated_at': '2026-11-01T00:00:00Z',
          'created_by': 'p-boss',
          'deleted': '0',
          'notes': 'boss',
        },
      ]);
      final a = device(anna);
      await synced(a);
      a.db.save(Tables.flights, {'id': 'f-boss', 'notes': 'mine now'});
      final mine = a.db.save(Tables.flights, {'notes': 'new'});
      await synced(a);
      expect(a.db.byId(Tables.flights, 'f-boss')!['notes'], 'boss');
      expect(a.db.byId(Tables.flights, mine)!['dirty'], 0);
      expect(a.pendingCount, 0);
    });

    test('the newer edit wins', () async {
      final a = device(anna);
      final boss = device(master);
      final id = a.db.save(Tables.flights, {'notes': 'first'});
      await synced(a);
      await synced(boss);
      // Anna's edit is older but reaches the server last.
      a.db.now = () => DateTime.utc(2030, 1, 1, 10);
      a.db.save(Tables.flights, {'id': id, 'notes': 'anna, older'});
      boss.db.now = () => DateTime.utc(2030, 1, 1, 11);
      boss.db.save(Tables.flights, {'id': id, 'notes': 'boss, newer'});
      await synced(boss);
      await synced(a);
      expect(a.db.byId(Tables.flights, id)!['notes'], 'boss, newer');
    });

    test('a viewer reads everything and changes nothing', () async {
      await seedRows('flights', [
        {
          'id': 'f1',
          'updated_at': '2026-11-01T00:00:00Z',
          'created_by': '',
          'deleted': '0',
        },
      ]);
      final v = device(vera);
      v.db.save(Tables.flights, {'notes': 'not allowed'});
      await synced(v);
      expect(v.readOnly, isTrue);
      expect(v.db.rows(Tables.flights).map((r) => r['id']), ['f1']);
    });

    test('the shared key adds rows; a turned off key stops', () async {
      final s = device(shared);
      final id = s.db.save(Tables.flights, {'notes': 'shared'});
      await synced(s);
      expect(s.db.byId(Tables.flights, id)!['dirty'], 0);
      expect(s.db.byId(Tables.flights, id)!['created_by'], isNull);

      final off = await makeKey({'kind': 'shared', 'active': false});
      final o = device(off);
      await o.sync();
      expect(o.lastError, contains('Access key not valid'));
    });

    test('competencies: a person gets only their own', () async {
      await seedRows('competencies', [
        {
          'id': 'c-anna',
          'updated_at': '2026-11-01T00:00:00Z',
          'person_id': 'p-anna',
          'type': 'GWO',
          'verified': '1',
        },
        {
          'id': 'c-boss',
          'updated_at': '2026-11-01T00:00:00Z',
          'person_id': 'p-boss',
          'type': 'GWO',
        },
      ]);
      final a = device(anna);
      await synced(a);
      expect(a.db.rows(Tables.competencies).map((r) => r['id']), ['c-anna']);
      a.db.save(Tables.competencies, {'id': 'c-anna', 'number': '123'});
      await synced(a);
      final boss = device(master);
      await synced(boss);
      expect(boss.db.rows(Tables.competencies), hasLength(2));
      final c = boss.db.byId(Tables.competencies, 'c-anna')!;
      expect(c['number'], '123');
      expect(c['verified'], isNull);
    });

    test('the admin makes and renews a person\'s key', () async {
      final boss = device(master);
      await synced(boss);
      final key1 = await boss.personKey('p-vera');
      expect(await boss.personKey('p-vera'), key1);
      final v = device(FirebaseKey.decode(key1)!);
      await synced(v);
      expect(v.me, 'p-vera');
      final key2 = await boss.personKey('p-vera', renew: true);
      expect(key2, isNot(key1));
      await v.sync();
      expect(v.lastError, contains('Access key not valid'));
      final v2 = device(FirebaseKey.decode(key2)!);
      await synced(v2);
    });

    test('many rows come down page by page', () async {
      for (var i = 0; i < 3; i++) {
        await seedRows('flights', [
          for (var j = 0; j < 400; j++)
            {
              'id': 'f-$i-$j',
              'updated_at': '2026-11-01T00:00:00Z',
              'deleted': '0',
            },
        ]);
      }
      final a = device(anna);
      await synced(a);
      expect(a.db.rows(Tables.flights), hasLength(1200));
      // Nothing new: nothing comes down again.
      final again = await a.sync();
      expect(again!.pulled, 0);
    });

    test('photos and documents go through Cloud Storage', () async {
      final a = device(anna);
      final faultId = a.db.save(Tables.faults, {'description': 'arm'});
      final photoId = a.photos!.add(
        a.db,
        faultId: faultId,
        bytes: Uint8List.fromList(List.generate(5000, (i) => i % 256)),
      );
      await synced(a);
      final row = a.db.byId(Tables.faultPhotos, photoId)!;
      expect(row['storage_path'], 'photos/$photoId.jpg');
      expect(row['dirty'], 0);

      final boss = device(master);
      await synced(boss);
      final f = await boss.photoFile(
        boss.db.byId(Tables.faultPhotos, photoId)!,
      );
      expect(f, isNotNull);
      expect(f!.lengthSync(), 5000);

      final tmp = Directory.systemTemp.createTempSync('doc');
      final pdf = File('${tmp.path}/manual.pdf')
        ..writeAsBytesSync(List.filled(70000, 7));
      final info = await boss.uploadDocument(pdf);
      final docId = boss.db.save(Tables.documents, {
        'title': 'Manual',
        ...info,
      });
      await synced(boss);
      await synced(a);
      // The sync starts downloading documents to keep offline.
      while (a.downloads.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final copy = await a.documentFile(a.db.byId(Tables.documents, docId)!);
      expect(copy, isNotNull, reason: a.downloadErrors.toString());
      expect(copy!.lengthSync(), 70000);
      // Pilots may not add documents.
      await expectLater(a.uploadDocument(pdf), throwsA(isA<SyncException>()));
    });

    test('the Sheets script hands out the Firebase key', () async {
      final s = SyncService(LocalDb.inMemory())
        ..firebaseFactory = ((k) => FirebaseClient(k, hosts: hosts))
        ..transportFactory = (_) => _Moved(anna.encode());
      expect(
        s.setAccessKey('https://script.google.com/macros/s/x/exec?key=old'),
        isTrue,
      );
      s.db.setLastSeq(Tables.flights, 42);
      final id = s.db.save(Tables.flights, {'notes': 'offline'});
      await synced(s);
      expect(s.usesFirebase, isTrue);
      expect(s.accessKey, anna.encode());
      expect(s.db.byId(Tables.flights, id)!['dirty'], 0);
    });
  });
}

class _Moved implements SyncTransport {
  _Moved(this.key);
  final String key;
  @override
  Future<Map<String, Object?>> call(Map<String, Object?> body) async =>
      throw MovedToFirebase(key);
}
