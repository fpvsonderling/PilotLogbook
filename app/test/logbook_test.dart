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
}
