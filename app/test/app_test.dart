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
    // The clock for landing opens at the take-off time.
    await tester.tap(find.byTooltip('Clock').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '13:00:00'), findsNWidgets(2));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Land'),
      '13:03:30',
    );
    // What takes several picks at once, e.g. a mission and Near miss.
    for (final what in ['Fiona Pickup', 'Near miss']) {
      final chip = find.widgetWithText(FilterChip, what);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }
    final rp = find.widgetWithText(DropdownButtonFormField<String?>, 'RP');
    await tester.ensureVisible(rp);
    await tester.pumpAndSettle();
    await tester.tap(rp);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pavlo Yavorskyi').last);
    await tester.pumpAndSettle();
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

  testWidgets('an inspection flight has only the Inspection LogBook fields', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.save(Tables.projects, {'name': 'Dogger Bank', 'active': 1});
    db.save(Tables.aircraft, {'name': '18', 'active': 1, 'usage': 'cargo'});
    final m30 = db.save(Tables.aircraft, {
      'name': 'Matrice 30T',
      'active': 1,
      'usage': 'inspection',
    });
    db.save(Tables.people, {
      'name': 'Andy Grimes',
      'roles': 'pilot',
      'active': 1,
    });

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Inspection LogBook'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    // The cargo drone and cargo fields are not offered.
    expect(find.widgetWithText(ChoiceChip, '18'), findsNothing);
    for (final cargoOnly in ['Battery', 'Used', 'What', 'Spotter']) {
      expect(find.text(cargoOnly), findsNothing, reason: cargoOnly);
    }
    await tester.tap(find.text('Dogger Bank'));
    await tester.tap(find.text('Matrice 30T'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Take off'),
      '03:14:15',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Land'),
      '03:25:00',
    );
    final rp = find.widgetWithText(DropdownButtonFormField<String?>, 'RP');
    await tester.tap(rp);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Andy Grimes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-flight')));
    await tester.pumpAndSettle();

    final flight = db.rows(Tables.flights).single;
    expect(flight['kind'], 'inspection');
    expect(flight['aircraft_id'], m30);
    expect(flight['duration_s'], 645);
    expect(flight['mission'], isNull);
    expect(find.text('0:10:45'), findsOneWidget);
    expect(find.text('Batt'), findsNothing);
  });

  testWidgets('batteries follow the drone chosen in a cargo flight', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    final d18 = db.save(Tables.aircraft, {'name': '18', 'active': 1});
    final d24 = db.save(Tables.aircraft, {'name': '24', 'active': 1});
    db.save(Tables.batteries, {'name': '45', 'active': 1, 'aircraft_ids': d18});
    db.save(Tables.batteries, {'name': '61', 'active': 1, 'aircraft_ids': d24});

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('18'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '45'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '61'), findsNothing);
    await tester.tap(find.text('24'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '45'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '61'), findsOneWidget);
  });

  testWidgets(
    'a drone is marked for cargo or inspection, a battery for its drones',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = LocalDb.inMemory();
      db.setSetting(SyncService.adminKey, '1');
      final d18 = db.save(Tables.aircraft, {'name': '18', 'active': 1});
      final battery = db.save(Tables.batteries, {'name': '45', 'active': 1});
      await tester.pumpWidget(PilotLogbookApp(db: db));
      await tester.tap(find.text('Reference data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Drones'));
      await tester.pumpAndSettle();
      expect(find.text('Cargo, Inspection'), findsOneWidget);
      await tester.tap(find.text('18'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('usage-inspection')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(db.byId(Tables.aircraft, d18)!['usage'], 'cargo');
      expect(find.text('Cargo'), findsOneWidget);

      await tester.tap(find.text('Batteries'));
      await tester.pumpAndSettle();
      expect(find.text('Any drone'), findsOneWidget);
      await tester.tap(find.text('45'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('battery-drone-18')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(db.byId(Tables.batteries, battery)!['aircraft_ids'], d18);
      expect(find.text('Drones 18'), findsOneWidget);
    },
  );

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
