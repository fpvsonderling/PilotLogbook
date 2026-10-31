import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';
import 'package:pilot_logbook/main.dart';

void main() {
  testWidgets('a pilot adds a cargo flight and sees it in the log', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.save(Tables.projects, {'name': 'Tjaereborg Enge', 'active': 1});
    db.save(Tables.aircraft, {'name': '18', 'active': 1});
    final battery = db.save(Tables.batteries, {'name': '45', 'active': 1});
    db.save(Tables.people, {
      'name': 'Pavlo Yavorskyi',
      'roles': 'pilot',
      'active': 1,
    });
    db.save(Tables.missionTypes, {'name': 'Fiona Pickup', 'active': 1});

    await tester.pumpWidget(PilotLogbookApp(db: db));
    expect(find.text('No flights yet'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tjaereborg Enge'));
    await tester.tap(find.text('18'));
    await tester.tap(find.text('45'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Take off'),
      '13:00:00',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Land'),
      '13:03:30',
    );
    await tester.enterText(find.widgetWithText(TextFormField, 'What'), 'Fio');
    await tester.pumpAndSettle();
    // Pick the suggestion, which also closes the suggestion list.
    await tester.tap(find.text('Fiona Pickup').last);
    await tester.pumpAndSettle();
    final rp = find.widgetWithText(DropdownButtonFormField<String?>, 'RP');
    await tester.ensureVisible(rp);
    await tester.pumpAndSettle();
    await tester.tap(rp);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pavlo Yavorskyi').last);
    await tester.pumpAndSettle();
    final nearMiss = find.text('Near miss');
    await tester.ensureVisible(nearMiss);
    await tester.pumpAndSettle();
    await tester.tap(nearMiss);
    await tester.tap(find.byKey(const Key('save-flight')));
    await tester.pumpAndSettle();

    final flight = db.rows(Tables.flights).single;
    expect(flight['mission'], 'Fiona Pickup, Near miss');
    expect(flight['kind'], 'cargo');
    expect(flight['duration_s'], 210);
    expect(flight['battery_id'], battery);
    expect(flight['near_miss'], 1);
    expect(flight['aborted'], isNull);
    expect(find.text('0:03:30'), findsOneWidget);
    expect(find.text('Cargo LogBook · 1 flights'), findsOneWidget);
  });

  testWidgets('only an admin can open and delete saved reference data', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.save(Tables.aircraft, {'name': '24', 'active': 1});
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Reference data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Drones'));
    await tester.pumpAndSettle();

    // A pilot: tapping does nothing, there is nothing to delete.
    await tester.tap(find.text('24'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);

    db.setSetting(SyncService.adminKey, '1');
    db.changes.notify();
    await tester.pumpAndSettle();
    await tester.tap(find.text('24'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-reference')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(db.rows(Tables.aircraft), isEmpty);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('saving an empty form shows what is missing', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-flight')));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsWidgets);
    expect(db.rows(Tables.flights), isEmpty);
  });

  testWidgets('Statistic counts aborted missions and near misses', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    final project = db.save(Tables.projects, {'name': 'Statkraft'});
    db.save(Tables.flights, {
      'date': '2026-10-30',
      'project_id': project,
      'duration_s': 210,
      'aborted': 1,
    });
    db.save(Tables.flights, {'date': '2026-10-30', 'project_id': project});
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Statistic'));
    await tester.pumpAndSettle();
    expect(find.text('Aborted missions'), findsOneWidget);
    expect(find.text('50.0% of flights'), findsOneWidget);
    expect(find.text('Statkraft'), findsOneWidget);
  });
}
