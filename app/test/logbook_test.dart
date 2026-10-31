import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/logbook.dart';
import 'package:pilot_logbook/data/schema.dart';

void main() {
  test('flight time from take-off and landing', () {
    expect(flightSeconds('13:00:00', '13:03:30'), 210);
    expect(flightSeconds('12:46:41', '12:51:20'), 279);
    expect(flightSeconds('23:59:00', '00:01:00'), 120);
    expect(flightSeconds('9:30', '9:33'), 180);
    expect(flightSeconds('25:00:00', '13:00:00'), isNull);
    expect(flightSeconds(null, '13:00:00'), isNull);
  });

  test('duration format matches the old app', () {
    expect(formatDuration(210), '0:03:30');
    expect(formatDuration(87 * 3600 + 16 * 60), '87:16:00');
    expect(formatDuration(null), '');
  });

  test('statistics count flights and time per pilot and spotter', () {
    final db = LocalDb.inMemory();
    final logbook = Logbook(db);
    final pavlo = db.save(Tables.people, {
      'name': 'Pavlo Yavorskyi',
      'roles': 'pilot',
    });
    final emil = db.save(Tables.people, {
      'name': 'Emil Palla',
      'roles': 'pilot, spotter',
    });
    final klaudiusz = db.save(Tables.people, {
      'name': 'Klaudiusz Hynek',
      'roles': 'spotter',
    });
    for (final (rp, spotter, seconds) in [
      (pavlo, klaudiusz, 210),
      (pavlo, klaudiusz, 279),
      (emil, klaudiusz, 100),
    ]) {
      db.save(Tables.flights, {
        'rp_id': rp,
        'spotter_id': spotter,
        'duration_s': seconds,
      });
    }
    final deleted = db.save(Tables.flights, {'rp_id': emil, 'duration_s': 999});
    db.delete(Tables.flights, deleted);

    final pilots = logbook.pilotStats();
    expect(
      [for (final p in pilots) (p.name, p.flights, p.seconds)],
      [('Pavlo Yavorskyi', 2, 489), ('Emil Palla', 1, 100)],
    );
    expect(logbook.spotterStats().single.flights, 3);
    expect(logbook.peopleWithRole('spotter').values, [
      'Emil Palla',
      'Klaudiusz Hynek',
    ]);
    expect(logbook.peopleWithRole('pilot').values, [
      'Emil Palla',
      'Pavlo Yavorskyi',
    ]);
  });

  test('totals and per project, drone, month and kind', () {
    final db = LocalDb.inMemory();
    final logbook = Logbook(db);
    final horns = db.save(Tables.projects, {'name': 'Horns Rev 2'});
    final dogger = db.save(Tables.projects, {'name': 'Dogger Bank'});
    final drone = db.save(Tables.aircraft, {'name': '19'});
    // The old flights say it in What only.
    db.save(Tables.flights, {
      'date': '2026-09-30',
      'kind': 'cargo',
      'project_id': dogger,
      'aircraft_id': drone,
      'mission': 'Double, Aborted',
    });
    db.save(Tables.flights, {
      'date': '2026-09-30',
      'kind': 'cargo',
      'project_id': dogger,
      'aircraft_id': drone,
      'mission': 'Sandra Delivery, Near miss',
    });
    for (final (date, project, seconds, aborted, nearMiss) in [
      ('2026-09-30', horns, 200, null, null),
      ('2026-10-01', horns, 300, 1, null),
      ('2026-10-01', horns, 100, null, 1),
      ('2026-10-02', dogger, 400, 1, 1),
      ('2026-10-02', null, null, null, null),
    ]) {
      db.save(Tables.flights, {
        'date': date,
        'kind': 'cargo',
        'project_id': project,
        'aircraft_id': project == null ? null : drone,
        'duration_s': seconds,
        'aborted': aborted,
        'near_miss': nearMiss,
      });
    }
    final deleted = db.save(Tables.flights, {
      'date': '2026-10-03',
      'aborted': 1,
    });
    db.delete(Tables.flights, deleted);

    final t = logbook.totals();
    expect(
      (t.all.flights, t.all.seconds, t.all.aborted, t.all.nearMisses),
      (7, 1000, 3, 3),
    );
    expect((t.days, t.longestSeconds), (3, 400));
    expect((t.firstDate, t.lastDate), ('2026-09-30', '2026-10-02'));
    expect(
      [
        for (final p in logbook.projectStats())
          (p.name, p.flights, p.seconds, p.aborted, p.nearMisses),
      ],
      [
        ('Dogger Bank', 3, 400, 2, 2),
        ('Horns Rev 2', 3, 600, 1, 1),
        ('No project', 1, 0, 0, 0),
      ],
    );
    expect(
      [for (final d in logbook.droneStats()) (d.name, d.flights)],
      [('19', 6), ('No drone', 1)],
    );
    expect(
      [for (final m in logbook.monthStats()) (m.name, m.flights)],
      [('2026-10', 4), ('2026-09', 3)],
    );
    expect(logbook.kindStats().single.name, 'cargo');
  });

  test('What splits into its picks, old spellings included', () {
    expect(missionParts('Double, Aborted'), ['Double', 'Aborted']);
    expect(missionParts(' Double , near-miss,'), ['Double', 'Near miss']);
    expect(missionParts('Fiona Pickup'), ['Fiona Pickup']);
    expect(missionParts(null), isEmpty);
  });

  test('tick boxes write Aborted / Near miss into What', () {
    expect(MissionTag.aborted.isIn('Double, Aborted'), isTrue);
    expect(MissionTag.nearMiss.isIn('Double, near-miss'), isTrue);
    expect(MissionTag.aborted.isIn('Fiona Pickup'), isFalse);
    expect(
      MissionTag.aborted.setIn('Fiona Pickup', true),
      'Fiona Pickup, Aborted',
    );
    expect(MissionTag.aborted.setIn('', true), 'Aborted');
    expect(MissionTag.aborted.setIn('Double, Aborted', false), 'Double');
    expect(
      MissionTag.nearMiss.setIn('Double, Near miss', true),
      'Double, Near miss',
    );
  });
}
