import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/checklists.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/logbook.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/main.dart';
import 'package:pilot_logbook/ui/daily_check_screen.dart';

void main() {
  test('every checklist section has its own column in the table', () {
    for (final c in checklists) {
      final columns = [for (final col in c.table.columns) col.name];
      expect(
        [for (final s in c.sections) s.column],
        columns.where(
          (n) =>
              !['checked_at', 'aircraft_id', 'pilot_id', 'notes'].contains(n),
        ),
        reason: c.name,
      );
    }
  });

  test('M30T drones get their own checklist, the rest are FB3', () {
    expect(checklistForDrone(name: '18'), fb3Checklist);
    expect(checklistForDrone(name: 'Matrice 30T'), m30tChecklist);
    expect(checklistForDrone(name: 'X', model: 'M30T'), m30tChecklist);
  });

  test('old AppSheet values read as results', () {
    expect(sectionResult('OK'), SectionResult.ok);
    expect(sectionResult('Ok'), SectionResult.ok);
    expect(sectionResult('Not used'), SectionResult.notUsed);
    expect(
      sectionResult('Ok, small play on the motor nr 8'),
      SectionResult.problem,
    );
    expect(sectionResult(''), isNull);
  });

  test('recent problems of a drone, newest first', () {
    final db = LocalDb.inMemory();
    final logbook = Logbook(db);
    final drone = db.save(Tables.aircraft, {'name': '18'});
    db.save(Tables.dailyChecksFb3, {
      'checked_at': '2026-10-26 08:00:00',
      'aircraft_id': drone,
      'landing_gear': 'Need to be replaced in future',
    });
    final latest = db.save(Tables.dailyChecksFb3, {
      'checked_at': '2026-10-27 08:00:00',
      'aircraft_id': drone,
      'motors_propellers': 'Prop 3 crack',
      'landing_gear': 'Ok',
    });
    final problems = logbook.recentProblems(drone);
    expect(
      [for (final p in problems) p.$3],
      ['Prop 3 crack', 'Need to be replaced in future'],
    );
    expect(
      logbook.recentProblems(drone, exceptId: latest).single.$3,
      'Need to be replaced in future',
    );
  });

  testWidgets('a pilot does an FB3 daily check with one problem', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    final drone = db.save(Tables.aircraft, {'name': '18', 'active': 1});
    final pilot = db.save(Tables.people, {
      'name': 'Pavlo',
      'roles': 'pilot',
      'active': 1,
    });

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Daily checks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New daily check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pavlo'));
    await tester.tap(find.text('18'));
    await tester.pumpAndSettle();
    expect(find.text('Motors and Propellers'), findsOneWidget);

    // Problem on the first section, by tapping the item itself.
    final item = find.text('Propellers: no cracks / deformation');
    await tester.tap(item);
    await tester.pumpAndSettle();
    await tester.tap(find.text('crack'));
    await tester.pumpAndSettle();

    // OK on every other section, N/A on the cargo compartment.
    final list = find
        .descendant(
          of: find.byType(DailyCheckScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    for (final s in fb3Checklist.sections.skip(1)) {
      await tester.scrollUntilVisible(
        find.text(s.title),
        200,
        scrollable: list,
      );
      final card = find.ancestor(
        of: find.text(s.title),
        matching: find.byType(Card),
      );
      final button = find.descendant(
        of: card,
        matching: find.text(s.column == 'cargo_compartment' ? 'N/A' : 'OK'),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('save-check')));
    await tester.pumpAndSettle();
    expect(find.text('1 problem'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-save-check')));
    await tester.pumpAndSettle();

    final row = db.rows(Tables.dailyChecksFb3).single;
    expect(row['aircraft_id'], drone);
    expect(row['pilot_id'], pilot);
    expect(
      row['motors_propellers'],
      'Propellers: no cracks / deformation: crack',
    );
    expect(row['cargo_compartment'], 'Not used');
    expect(row['storage'], 'Ok');
    expect(find.text('Daily checks · 1'), findsOneWidget);
    expect(db.setting('daily_check_last_pilot_id'), pilot);
  });
}
