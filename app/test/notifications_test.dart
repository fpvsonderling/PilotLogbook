import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/notifications.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';
import 'package:pilot_logbook/main.dart';

/// Drones 19 and 24, Anna (pilot), Tom (pilot), a fault on each drone
/// reported by Tom today and drone 19 flown 9 h (Propulsion due soon).
({LocalDb db, String anna, String tom, String d19, String d24}) _world() {
  final db = LocalDb.inMemory();
  final today = DateTime.now();
  String day(int back) {
    final d = today.subtract(Duration(days: back));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  final anna = db.save(Tables.people, {'name': 'Anna', 'roles': 'pilot'});
  final tom = db.save(Tables.people, {'name': 'Tom', 'roles': 'pilot'});
  final d19 = db.save(Tables.aircraft, {'name': '19', 'model': 'FB3'});
  final d24 = db.save(Tables.aircraft, {'name': '24', 'model': 'FB3'});
  for (var i = 0; i < 9; i++) {
    db.save(Tables.flights, {
      'date': day(i + 1),
      'aircraft_id': d19,
      'rp_id': anna,
      'duration_s': 3600,
    });
  }
  db.save(Tables.faults, {
    'reported_at': '${day(0)} 08:00:00',
    'aircraft_id': d19,
    'severity': 2,
    'description': 'cracked arm',
    'discovered_by_id': tom,
  });
  db.save(Tables.faults, {
    'reported_at': '${day(0)} 09:00:00',
    'aircraft_id': d24,
    'severity': 3,
    'description': 'GPS',
    'discovered_by_id': tom,
  });
  return (db: db, anna: anna, tom: tom, d19: d19, d24: d24);
}

void main() {
  test(
    'a pilot gets nothing until they switch it on, then only their drones',
    () {
      final w = _world();
      final n = Notifications(w.db, me: w.anna, admin: false, viewer: false);
      expect(n.prefs().on.values.any((v) => v), isFalse);
      expect(n.inbox(), isEmpty);
      expect(n.recentDrones(), {w.d19});

      n.save(
        n.prefs().copyWith(
          on: {'faults': true, 'maintenance': true},
          drones: {w.d19},
        ),
      );
      final titles = [for (final i in n.inbox()) i.title];
      expect(titles, contains('New fault: drone 19'));
      expect(titles, contains('Maintenance due soon: Drone 19'));
      expect(titles.any((t) => t.contains('24')), isFalse);
      // Saved in its own row, which goes to Firebase like the others.
      final row = w.db.byId(Tables.notifySettings, 'notify-${w.anna}')!;
      expect(row['person_id'], w.anna);
      expect(row['aircraft_ids'], w.d19);
      expect(row['faults'], 1);
      expect(row['repairs'], 0);
    },
  );

  test('the admin too starts with nothing, then gets every drone', () {
    final w = _world();
    final n = Notifications(w.db, me: null, admin: true, viewer: false);
    expect(n.owner, Notifications.master);
    expect(n.prefs().on.values.any((v) => v), isFalse);
    expect(n.inbox(), isEmpty);
    n.save(
      n.prefs().copyWith(on: {for (final t in notifyTypes) t.column: true}),
    );
    final titles = [for (final i in n.inbox()) i.title];
    expect(titles.first, 'Grounded: drone 24');
    expect(titles, contains('New fault: drone 19'));

    n.save(n.prefs().copyWith(on: {...n.prefs().on, 'faults': false}));
    expect(n.inbox().any((i) => i.title.contains('fault')), isFalse);
  });

  test(
    'a viewer gets nothing; the reporter is not told of their own fault',
    () {
      final w = _world();
      final viewer = Notifications(w.db, me: w.tom, admin: false, viewer: true);
      expect(viewer.available, isFalse);
      expect(viewer.inbox(), isEmpty);

      final tom = Notifications(w.db, me: w.tom, admin: false, viewer: false);
      tom.save(
        tom.prefs().copyWith(on: {'faults': true}, drones: {w.d19, w.d24}),
      );
      expect(tom.inbox(), isEmpty);
    },
  );

  test('seen and new items', () {
    final w = _world();
    final n = Notifications(w.db, me: null, admin: true, viewer: false);
    n.save(n.prefs().copyWith(on: {'faults': true, 'maintenance': true}));
    expect(n.unseen(), hasLength(n.inbox().length));
    n.markSeen();
    expect(n.unseen(), isEmpty);
    // The first look only remembers; later ones give what is new.
    expect(n.takeNew(), isEmpty);
    w.db.save(Tables.faults, {
      'reported_at': '2999-01-01 08:00:00',
      'aircraft_id': w.d19,
      'description': 'motor',
    });
    expect([for (final i in n.takeNew()) i.title], ['New fault: drone 19']);
    expect(n.takeNew(), isEmpty);
  });

  testWidgets(
    'a pilot switches on faults and ticks a drone; the bell shows it',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final w = _world();
      w.db.setSetting(LocalDb.meKey, w.anna);
      await tester.pumpWidget(PilotLogbookApp(db: w.db, push: false));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notification-bell')), findsOneWidget);

      await tester.tap(find.text('Settings').last);
      await tester.pumpAndSettle();
      // Not for a pilot: the team's competencies.
      expect(find.byKey(const Key('notify-team_competencies')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('notify-faults')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('notify-faults')));
      await tester.pumpAndSettle();
      expect(find.textContaining('flown recently'), findsOneWidget);
      await tester.ensureVisible(find.byKey(Key('my-drone-${w.d19}')));
      await tester.tap(find.byKey(Key('my-drone-${w.d19}')));
      await tester.pumpAndSettle();

      expect(find.byTooltip('1 new notification'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notification-bell')));
      await tester.pumpAndSettle();
      expect(find.text('New fault: drone 19'), findsOneWidget);
      await tester.tap(find.text('New fault: drone 19'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Notifications'), findsOneWidget);
      expect(find.text('cracked arm'), findsWidgets);
    },
  );

  test('notify_settings and push_devices are personal tables', () {
    expect(Tables.personal, contains(Tables.notifySettings));
    expect(Tables.personal, contains(Tables.pushDevices));
    expect(SyncService.adminKey, isNotEmpty);
  });
}
