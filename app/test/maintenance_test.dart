import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/maintenance.dart';
import 'package:pilot_logbook/data/maintenance_guide.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/main.dart';

void main() {
  test('every maintenance section has its own column in the table', () {
    expect(
      [for (final s in maintenanceSections) s.column],
      [
        for (final c in Tables.maintenance.columns)
          if (![
            'performed_at',
            'aircraft_id',
            'technician_id',
            'notes',
          ].contains(c.name))
            c.name,
      ],
    );
  });

  test('flying since the last maintenance, per drone', () {
    final db = LocalDb.inMemory();
    final log = MaintenanceLog(db, today: () => DateTime(2026, 9, 2));
    final d18 = db.save(Tables.aircraft, {'name': '18', 'active': 1});
    final d24 = db.save(Tables.aircraft, {'name': '24', 'active': 1});
    db.save(Tables.maintenance, {
      'performed_at': '2026-08-07 10:48:45',
      'aircraft_id': d18,
      'arm_assembly': 'Replaced 3 propellers.',
      'center_plate': 'Checked',
    });
    void flight(String drone, String date, String takeoff, int seconds) =>
        db.save(Tables.flights, {
          'date': date,
          'aircraft_id': drone,
          'takeoff_at': takeoff,
          'duration_s': seconds,
        });
    flight(d18, '2026-08-07', '09:00:00', 600); // before, same day
    flight(d18, '2026-08-07', '12:00:00', 900);
    flight(d18, '2026-09-01', '08:00:00', 1800);
    flight(d24, '2026-09-01', '08:00:00', 300);

    final drones = log.drones();
    // A drone never maintained comes first.
    expect([for (final d in drones) d.name], ['24', '18']);
    final s18 = drones.last;
    expect(s18.flightsSince, 2);
    expect(s18.secondsSince, 2700);
    expect(drones.first.last, isNull);
    expect(drones.first.flightsSince, 1);

    final m = log.all().single;
    expect(m.done.length, 2);
    expect(
      [for (final (s, t) in m.work) '${s.title}: $t'],
      ['Arm Assembly: Replaced 3 propellers.'],
    );
  });

  testWidgets('a technician saves a maintenance', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    final drone = db.save(Tables.aircraft, {'name': '18', 'active': 1});
    final tech = db.save(Tables.people, {
      'name': 'Michał',
      'roles': 'technician',
      'active': 1,
    });

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Maintenance'));
    await tester.pumpAndSettle();
    expect(find.text('No maintenance yet'), findsWidgets);
    await tester.tap(find.text('New maintenance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Michał'));
    await tester.tap(find.text('18'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('all-checked')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('work-propulsion_system')),
      'Replaced 3 propellers',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-maintenance')));
    await tester.pumpAndSettle();

    final row = db.rows(Tables.maintenance).single;
    expect(row['aircraft_id'], drone);
    expect(row['technician_id'], tech);
    expect(row['arm_assembly'], 'Checked');
    expect(row['propulsion_system'], 'Replaced 3 propellers');
    expect(row['fts'], 'Checked');
    expect(find.text('Maintenance · 1'), findsOneWidget);
    expect(find.text('7 / 7 checked'), findsOneWidget);
  });

  testWidgets('drone tiles fit two per row on a phone', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.save(Tables.aircraft, {'name': '18', 'active': 1});
    db.save(Tables.aircraft, {'name': '19', 'active': 1});

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maintenance'));
    await tester.pumpAndSettle();
    // The drawer's own long labels overflow while it closes; not this page.
    tester.takeException();
    await tester.pump();
    final a = tester.getTopLeft(find.text('Drone 18'));
    final b = tester.getTopLeft(find.text('Drone 19'));
    expect(a.dy, b.dy);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each assembly has an instruction button', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.save(Tables.aircraft, {'name': '18', 'active': 1});
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Maintenance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New maintenance'));
    await tester.pumpAndSettle();
    for (final s in maintenanceSections) {
      await tester.scrollUntilVisible(
        find.byKey(Key('guide-${s.column}')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.scrollUntilVisible(
      find.byKey(const Key('guide-arm_assembly')),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('guide-arm_assembly')));
    await tester.pumpAndSettle();
    expect(find.text('Arm Assembly GVI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('every assembly has an instruction and its pictures exist', () {
    for (final s in maintenanceSections) {
      final guide = maintenanceGuides[s.column];
      expect(guide?.tasks, isNotEmpty, reason: s.column);
      for (final t in guide!.tasks) {
        for (final image in t.images) {
          expect(File(image).existsSync(), isTrue, reason: image);
        }
      }
    }
  });

  test('assemblies are due by hours, flights or days', () {
    final db = LocalDb.inMemory();
    final log = MaintenanceLog(db, today: () => DateTime(2026, 11, 3));
    final d18 = db.save(Tables.aircraft, {
      'name': '18',
      'model': 'FB3',
      'active': 1,
    });
    db.save(Tables.maintenance, {
      'performed_at': '2026-10-01 08:00:00',
      'aircraft_id': d18,
      for (final s in maintenanceSections) s.column: 'Checked',
    });
    // 8:30 h flown since: propellers (10 h) are at 85 %, due soon.
    for (var i = 0; i < 17; i++) {
      db.save(Tables.flights, {
        'date': '2026-10-${(10 + i).toString().padLeft(2, '0')}',
        'aircraft_id': d18,
        'takeoff_at': '10:00:00',
        'duration_s': 1800,
      });
    }
    var d = log.drones().single;
    SectionDue of(String column) =>
        d.sections.firstWhere((s) => s.section.column == column);
    expect(of('propulsion_system').level, DueLevel.soon);
    expect(of('arm_assembly').level, DueLevel.ok); // 8.5 of 20 h
    expect(of('fts').level, DueLevel.ok); // 33 of 182 days
    expect(d.level, DueLevel.soon);
    expect(log.dueCount(), 1);

    // The admin: every 30 flights for all drones, FTS every 30 days for FB3.
    db.save(Tables.maintenanceIntervals, {
      'section': 'arm_assembly',
      'flights': 15,
    });
    db.save(Tables.maintenanceIntervals, {
      'model': 'fb3',
      'section': 'fts',
      'days': 30,
    });
    // An empty row turns the reminder off.
    db.save(Tables.maintenanceIntervals, {
      'model': 'FB3',
      'section': 'propulsion_system',
    });
    d = log.drones().single;
    expect(of('arm_assembly').level, DueLevel.overdue);
    expect(of('arm_assembly').describe(), '2 flights over');
    expect(of('fts').level, DueLevel.overdue);
    expect(of('propulsion_system').interval.isOff, isTrue);
    expect(of('propulsion_system').level, DueLevel.ok);
    expect(of('power_system').interval.hours, 10); // still the book's

    // A drone never maintained counts all its flying, not days.
    final d19 = db.save(Tables.aircraft, {'name': '19', 'active': 1});
    db.save(Tables.flights, {
      'date': '2026-01-01',
      'aircraft_id': d19,
      'takeoff_at': '10:00:00',
      'duration_s': 11 * 3600,
    });
    final d19m = log.drones().firstWhere((x) => x.aircraftId == d19);
    expect(d19m.due.map((s) => s.section.column), [
      'propulsion_system',
      'load_assembly',
      'power_system',
    ]);
    expect(d19m.level, DueLevel.overdue);
  });

  testWidgets('a drone due shows on its tile and at the top', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    final drone = db.save(Tables.aircraft, {'name': '18', 'active': 1});
    db.save(Tables.aircraft, {'name': '19', 'active': 1});
    db.save(Tables.flights, {
      'date': '2026-01-01',
      'aircraft_id': drone,
      'takeoff_at': '10:00:00',
      'duration_s': 12 * 3600,
    });
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('alert-maintenance')), findsOneWidget);
    await tester.tap(find.byKey(const Key('alert-maintenance')));
    await tester.pumpAndSettle();
    expect(
      find.text('Due: Propulsion System, Load Assembly, Power System'),
      findsOneWidget,
    );
    await tester.tap(find.text('Drone 18'));
    await tester.pumpAndSettle();
    expect(find.text('2:00 h over'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
