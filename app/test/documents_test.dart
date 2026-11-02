import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/documents.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';
import 'package:pilot_logbook/main.dart';

import 'sync_test.dart' show FakeSheets;

/// FakeSheets plus the script's document actions, over in-memory "Drive"
/// files sent back in pieces of [piece] bytes.
class FakeDrive extends FakeSheets {
  final files = <String, List<int>>{};
  final versions = <String, String>{};
  var piece = 4;
  var parts = 0;
  var offline = false;

  @override
  Future<Map<String, Object?>> call(Map<String, Object?> body) async {
    if (offline) throw const SocketException('offline');
    final admin = body['token'] == 'admin-secret';
    switch (body['action']) {
      case 'documentUpload':
        if (!admin) throw SyncException('Only the admin can add documents');
        return {
          'ok': true,
          'upload_url': 'https://upload.test/${body['name']}',
        };
      case 'documentInfo':
        if (!admin) throw SyncException('Only the admin can add documents');
        final id = body['drive_file_id'] as String;
        return {
          'ok': true,
          'drive_file_id': id,
          'file_name': '$id.pdf',
          'mime_type': 'application/pdf',
          'size_bytes': '${files[id]!.length}',
          'file_version': versions[id],
          'url': 'https://drive.test/$id',
        };
      case 'documentPart':
        parts++;
        final bytes = files[body['drive_file_id']]!;
        final offset = body['offset'] as int;
        final end = (offset + piece).clamp(0, bytes.length);
        return {
          'ok': true,
          'size': bytes.length,
          'data': base64Encode(bytes.sublist(offset.clamp(0, end), end)),
        };
    }
    return super.call(body);
  }
}

Future<SyncService> deviceWithDocuments(
  FakeDrive drive,
  Directory dir, {
  bool admin = false,
}) async {
  final db = LocalDb.inMemory();
  db.setSetting(SyncService.urlKey, 'https://example.test/exec');
  db.setSetting(SyncService.tokenKey, admin ? 'admin-secret' : 'secret');
  return SyncService(db, documents: DocumentStore(dir.path))
    ..transportFactory = ((_) => drive)
    ..uploader = (url, file, mime) async {
      final id = 'up-${file.uri.pathSegments.last}';
      drive.files[id] = await file.readAsBytes();
      drive.versions[id] = 'v1';
      return {'id': id};
    };
}

/// Lets the downloads started after a sync finish.
Future<void> settle(SyncService s) async {
  for (var i = 0; i < 50 && s.downloads.isNotEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('docs'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('drive links: file, open and Docs links, a bare id', () {
    const id = '1AbCdEfGhIjKlMnOpQrStUvWxYz';
    expect(driveFileId('https://drive.google.com/file/d/$id/view'), id);
    expect(driveFileId('https://drive.google.com/open?id=$id'), id);
    expect(driveFileId('https://docs.google.com/document/d/$id/edit'), id);
    expect(driveFileId(id), id);
    expect(driveFileId('https://example.com/manual.pdf'), isNull);
  });

  test(
    'the admin uploads a document; a pilot gets it once, offline after',
    () async {
      final drive = FakeDrive();
      final admin = await deviceWithDocuments(
        drive,
        Directory('${tmp.path}/admin'),
        admin: true,
      );
      final pilot = await deviceWithDocuments(
        drive,
        Directory('${tmp.path}/pilot'),
      );

      final source = File('${tmp.path}/OM.pdf')
        ..writeAsBytesSync(List.generate(10, (i) => i));
      final info = await admin.uploadDocument(source);
      final id = admin.db.save(Tables.documents, {'title': 'OM', ...info});
      admin.documents!.keep(admin.db.byId(Tables.documents, id)!, source);
      await admin.sync();
      await settle(admin);
      expect(drive.parts, 0, reason: 'the admin keeps the file it uploaded');

      await pilot.sync();
      await settle(pilot);
      final row = pilot.db.byId(Tables.documents, id)!;
      final copy = pilot.documents!.cached(row);
      expect(copy, isNotNull);
      expect(copy!.readAsBytesSync(), List.generate(10, (i) => i));
      expect(drive.parts, 3, reason: '10 bytes in pieces of 4');

      // Opening it again, and syncing again, downloads nothing.
      drive.offline = true;
      expect((await pilot.documentFile(row))!.path, copy.path);
      drive.offline = false;
      await pilot.sync();
      await settle(pilot);
      expect(drive.parts, 3);
    },
  );

  test(
    'a new version is downloaded again; offline the old copy opens',
    () async {
      final drive = FakeDrive()
        ..files['d1'] = [1, 2, 3]
        ..versions['d1'] = 'v1';
      final admin = await deviceWithDocuments(
        drive,
        Directory('${tmp.path}/admin'),
        admin: true,
      );
      final pilot = await deviceWithDocuments(
        drive,
        Directory('${tmp.path}/pilot'),
      );
      pilot.keepDocumentsOffline = false;
      final id = admin.db.save(Tables.documents, {
        'title': 'Checklist',
        ...await admin.documentInfo('d1'),
      });
      await admin.sync();
      await settle(admin);
      drive.parts = 0;
      await pilot.sync();
      await settle(pilot);
      expect(drive.parts, 0, reason: 'only when opened, with the switch off');
      final f = await pilot.documentFile(pilot.db.byId(Tables.documents, id)!);
      expect(f!.readAsBytesSync(), [1, 2, 3]);

      drive.files['d1'] = [9, 9];
      admin.db.save(Tables.documents, {'id': id, 'file_version': 'v2'});
      await admin.sync();
      await pilot.sync();
      final row = pilot.db.byId(Tables.documents, id)!;
      expect(pilot.documents!.cached(row), isNull);
      drive.offline = true;
      expect((await pilot.documentFile(row))!.readAsBytesSync(), [1, 2, 3]);
      drive.offline = false;
      expect((await pilot.documentFile(row))!.readAsBytesSync(), [9, 9]);
    },
  );

  test(
    'pilots cannot add or delete documents; deleted ones leave the device',
    () async {
      final drive = FakeDrive()
        ..files['d1'] = [1]
        ..versions['d1'] = 'v1';
      final admin = await deviceWithDocuments(
        drive,
        Directory('${tmp.path}/admin'),
        admin: true,
      );
      final pilot = await deviceWithDocuments(
        drive,
        Directory('${tmp.path}/pilot'),
      );
      final id = admin.db.save(Tables.documents, {
        'title': 'OM',
        ...await admin.documentInfo('d1'),
      });
      await admin.sync();
      await pilot.sync();
      await settle(pilot);

      final own = pilot.db.save(Tables.documents, {'title': 'Mine'});
      pilot.db.delete(Tables.documents, id);
      await pilot.sync();
      await settle(pilot);
      expect(pilot.db.byId(Tables.documents, own), isNull);
      expect(pilot.db.byId(Tables.documents, id)!['deleted'], 0);
      expect(() => pilot.documentInfo('d1'), throwsA(isA<SyncException>()));

      admin.db.delete(Tables.documents, id);
      await admin.sync();
      await pilot.sync();
      expect(pilot.documents!.folder(id).existsSync(), isFalse);
    },
  );

  testWidgets('everyone sees the documents; only the admin gets Add', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = LocalDb.inMemory();
    db.save(Tables.documents, {
      'title': 'Operations Manual',
      'notes': 'Read before flying',
      'drive_file_id': 'd1',
      'file_name': 'OM.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 2400000,
    });
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Documents'));
    await tester.pumpAndSettle();
    expect(find.text('Operations Manual'), findsOneWidget);
    expect(find.text('OM.pdf · 2.3 MB'), findsOneWidget);
    expect(find.byKey(const Key('add-document')), findsNothing);

    db.setSetting(SyncService.adminKey, '1');
    db.save(Tables.documents, {'title': 'Another'});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-document')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-document')));
    await tester.pumpAndSettle();
    expect(find.text('Google Drive link'), findsWidgets);
  });
}
