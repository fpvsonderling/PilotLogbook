import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/logbook.dart';
import 'package:pilot_logbook/data/photos.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';
import 'package:pilot_logbook/main.dart';

import 'sync_test.dart' show FakeSheets;

/// FakeSheets plus the script's photo actions, with Drive as a map.
class FakeSheetsWithDrive extends FakeSheets {
  final drive = <String, String>{};
  var uploads = 0;

  @override
  Future<Map<String, Object?>> call(Map<String, Object?> body) async {
    switch (body['action']) {
      case 'uploadPhoto':
        uploads++;
        final id = 'drive-${drive.length + 1}';
        drive[id] = body['data'] as String;
        return {'ok': true, 'drive_file_id': id, 'url': 'https://drive/$id'};
      case 'photo':
        return {'ok': true, 'data': drive[body['drive_file_id']]};
    }
    return super.call(body);
  }
}

SyncService device(FakeSheets sheets, String photoDir) {
  final db = LocalDb.inMemory();
  db.setSetting(SyncService.urlKey, 'https://example.test/exec');
  db.setSetting(SyncService.tokenKey, 'admin-secret');
  return SyncService(db, photos: PhotoStore(photoDir))
    ..transportFactory = (_) => sheets;
}

void main() {
  test('status: open, repaired, failed test, repaired again, closed', () {
    final db = LocalDb.inMemory();
    final logbook = Logbook(db);
    final id = db.save(Tables.faults, {
      'reported_at': '2026-10-01 10:00:00',
      'severity': 3,
      'description': 'Melted connector',
    });
    FaultCase c() => logbook.faultCase(id)!;
    expect(c().status, FaultStatus.open);
    expect(c().grounded, isTrue);

    db.save(Tables.faultRepairs, {
      'fault_id': id,
      'started_at': '2026-10-02 09:00:00',
      'finished_at': '2026-10-02 10:00:00',
    });
    expect(c().status, FaultStatus.repaired);
    expect(c().grounded, isTrue);

    db.save(Tables.faultSignoffs, {
      'fault_id': id,
      'tested_at': '2026-10-02 11:00:00',
      'result': 'fail',
    });
    expect(c().status, FaultStatus.open);

    db.save(Tables.faultRepairs, {
      'fault_id': id,
      'started_at': '2026-10-03 09:00:00',
    });
    expect(c().status, FaultStatus.repaired);

    db.save(Tables.faultSignoffs, {
      'fault_id': id,
      'tested_at': '2026-10-03 12:00:00',
      'result': 'pass',
    });
    expect(c().status, FaultStatus.closed);
    expect(c().grounded, isFalse);
  });

  test('open faults come first, grounded on top', () {
    final db = LocalDb.inMemory();
    final minor = db.save(Tables.faults, {
      'reported_at': '2026-10-05 10:00:00',
      'severity': 1,
    });
    final grounded = db.save(Tables.faults, {
      'reported_at': '2026-10-01 10:00:00',
      'severity': 3,
    });
    final closed = db.save(Tables.faults, {
      'reported_at': '2026-10-09 10:00:00',
      'severity': 3,
    });
    db.save(Tables.faultSignoffs, {'fault_id': closed, 'result': 'pass'});
    expect(Logbook(db).faultCases().map((c) => c.id), [
      grounded,
      minor,
      closed,
    ]);
  });

  test('a photo taken offline is uploaded on sync and shown on another '
      'device', () async {
    final dir = Directory.systemTemp.createTempSync('photos');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sheets = FakeSheetsWithDrive();
    final phone = device(sheets, '${dir.path}/phone');
    final pc = device(sheets, '${dir.path}/pc');

    final fault = phone.db.save(Tables.faults, {'description': 'Prop chip'});
    final photo = phone.photos!.add(
      phone.db,
      faultId: fault,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    expect(phone.photos!.pendingUploads(phone.db), hasLength(1));

    await phone.sync();
    expect(phone.lastError, isNull);
    expect(sheets.uploads, 1);
    expect(sheets.drive.values.single, base64Encode([1, 2, 3]));
    expect(
      sheets.tables['fault_photos']![photo]!['drive_file_id'],
      'drive-1',
    );
    expect(phone.photos!.pendingUploads(phone.db), isEmpty);

    // A second sync sends nothing again.
    await phone.sync();
    expect(sheets.uploads, 1);

    await pc.sync();
    final row = pc.db.byId(Tables.faultPhotos, photo)!;
    final file = await pc.photoFile(row);
    expect(file!.readAsBytesSync(), [1, 2, 3]);
  });

  testWidgets('report a grounded fault, repair it and sign it off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.save(Tables.aircraft, {'name': '24', 'active': 1});
    db.save(Tables.people, {
      'name': 'Emil Palla',
      'roles': 'pilot,signatory',
      'active': 1,
    });
    // The admin link: may sign off.
    db.setSetting(SyncService.adminKey, '1');

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Fault Repair'));
    await tester.pumpAndSettle();
    expect(find.text('No faults reported'), findsOneWidget);

    await tester.tap(find.text('Report fault'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '24'));
    await tester.tap(find.text(severityTitle(3)));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'What is wrong'),
      'Melted connector',
    );
    final by = find.widgetWithText(
      DropdownButtonFormField<String?>,
      'Discovered by',
    );
    await tester.ensureVisible(by);
    await tester.pumpAndSettle();
    await tester.tap(by);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emil Palla').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-fault-form')));
    await tester.pumpAndSettle();

    expect(find.text('GROUNDED: Drone 24'), findsOneWidget);
    expect(find.text('Melted connector'), findsOneWidget);

    await tester.tap(find.text('Melted connector'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record repair'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Technicians'),
      'Adam Madziala',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Work performed'),
      'Connector replaced',
    );
    await tester.tap(find.byKey(const Key('save-fault-form')));
    await tester.pumpAndSettle();
    expect(find.text('Repaired · waiting for test'), findsOneWidget);

    await tester.tap(find.text('Test and sign off'));
    await tester.pumpAndSettle();
    final signatory = find.widgetWithText(
      DropdownButtonFormField<String?>,
      'Authorized signatory',
    );
    await tester.tap(signatory);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emil Palla').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-fault-form')));
    await tester.pumpAndSettle();
    expect(find.text('Fixed and tested'), findsOneWidget);
    expect(find.text('Record repair'), findsNothing);

    final c = Logbook(db).faultCases().single;
    expect(c.status, FaultStatus.closed);
    expect(c.repairs.single['work_performed'], 'Connector replaced');
    expect(c.passedSignoff!['signatory_id'], isNotNull);
  });
}

String severityTitle(int s) => switch (s) {
  3 => 'Class 3: Critical – UAS GROUNDED',
  _ => '',
};
