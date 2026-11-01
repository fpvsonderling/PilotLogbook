import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/maintenance.dart';
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
    final log = MaintenanceLog(db);
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
}
