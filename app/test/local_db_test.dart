import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';

void main() {
  late LocalDb db;
  var clock = DateTime.utc(2026, 10, 28, 10);

  setUp(() {
    db = LocalDb.inMemory()..now = () => clock;
  });

  test('a local save is marked for upload with all columns', () {
    final id = db.save(Tables.flights, {
      'date': '2026-10-28',
      'notes': 'Strong wind',
    });
    final dirty = db.dirtyRows(Tables.flights).single;
    expect(dirty['id'], id);
    expect(dirty['updated_at'], '2026-10-28T10:00:00.000Z');
    expect(dirty.keys, Tables.flights.columnNames);
  });

  test('editing keeps fields that were not passed', () {
    final id = db.save(Tables.flights, {'date': '2026-10-28', 'notes': 'a'});
    db.save(Tables.flights, {'id': id, 'notes': 'b'});
    expect(db.byId(Tables.flights, id)!['date'], '2026-10-28');
    expect(db.byId(Tables.flights, id)!['notes'], 'b');
  });

  test('markSynced keeps the flag when the row changed during upload', () {
    final id = db.save(Tables.flights, {'notes': 'a'});
    final sent = db.dirtyRows(Tables.flights).single['updated_at'] as String;
    clock = clock.add(const Duration(seconds: 5));
    db.save(Tables.flights, {'id': id, 'notes': 'b'});
    db.markSynced(Tables.flights, id, sent, 1);
    expect(db.dirtyRows(Tables.flights), hasLength(1));
  });

  test('remote rows are converted from sheet text', () {
    db.applyRemote(Tables.flights, {
      'id': 'r1',
      'updated_at': '2026-10-28T09:00:00Z',
      'server_seq': '4',
      'deleted': '0',
      'battery_pct': '45',
      'used': '3,4',
      'notes': '',
    });
    final r = db.byId(Tables.flights, 'r1')!;
    expect(r['battery_pct'], 45);
    expect(r['used'], 3.4);
    expect(r['notes'], isNull);
    expect(r['dirty'], 0);
  });

  test('a newer local edit wins over an older remote row', () {
    final id = db.save(Tables.flights, {'notes': 'local'});
    db.applyRemote(Tables.flights, {
      'id': id,
      'updated_at': '2026-10-28T09:00:00Z',
      'notes': 'remote',
    });
    expect(db.byId(Tables.flights, id)!['notes'], 'local');

    db.applyRemote(Tables.flights, {
      'id': id,
      'updated_at': '2026-10-28T11:00:00Z',
      'notes': 'remote newer',
    });
    expect(db.byId(Tables.flights, id)!['notes'], 'remote newer');
    expect(db.dirtyRows(Tables.flights), isEmpty);
  });

  test('deleted rows are hidden from reads', () {
    final id = db.save(Tables.projects, {'name': 'Tjaereborg Enge'});
    db.delete(Tables.projects, id);
    expect(db.rows(Tables.projects), isEmpty);
    expect(db.dirtyRows(Tables.projects).single['deleted'], 1);
  });
}
