import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';

/// In-memory stand-in for the spreadsheet script, with the same contract as
/// apps_script/Code.gs (that file has its own tests). Token 'secret' is the
/// pilots' link, 'admin-secret' the admin link, 'anna-secret' Anna's own.
class FakeSheets implements SyncTransport {
  final tables = <String, Map<String, Map<String, Object?>>>{};
  var seq = 0;
  var calls = 0;

  @override
  Future<Map<String, Object?>> call(Map<String, Object?> body) async {
    calls++;
    final admin = body['token'] == 'admin-secret';
    final me = body['token'] == 'anna-secret' ? 'p-anna' : '';
    if (!admin && me.isEmpty && body['token'] != 'secret') {
      throw SyncException('Wrong access token');
    }
    final push = body['push'] as Map<String, List<DbRow>>;
    final since = body['since'] as Map<String, int>;
    final accepted = <String, List<Object?>>{};
    final pulled = <String, List<Object?>>{};
    final seqs = <String, int>{};
    final denied = <String, List<Object?>>{};
    for (final t in Tables.all) {
      final rows = tables.putIfAbsent(t.name, () => {});
      final ok = accepted[t.name] = [];
      final rejected = <String>{};
      final no = denied[t.name] = [];
      for (final r in push[t.name] ?? const <DbRow>[]) {
        final id = r['id'] as String;
        final existing = rows[id];
        final own =
            existing != null && me.isNotEmpty && existing['created_by'] == me;
        if (!admin &&
            (existing != null
                ? existing['updated_at'] != r['updated_at'] && !own
                : r['deleted'] == 1)) {
          if (existing != null) rejected.add(id);
          no.add(id);
          continue;
        }
        if (existing != null &&
            (existing['updated_at'] as String).compareTo(
                  r['updated_at'] as String,
                ) >
                0) {
          rejected.add(id);
          continue;
        }
        seq++;
        rows[id] = {
          for (final e in r.entries) e.key: e.value?.toString() ?? '',
          'server_seq': '$seq',
          'created_by': existing != null
              ? existing['created_by']
              : admin
              ? r['created_by']?.toString() ?? ''
              : me,
        };
        ok.add({'id': id, 'updated_at': r['updated_at'], 'server_seq': seq});
      }
      final from = since[t.name] ?? 0;
      pulled[t.name] = [
        for (final r in rows.values)
          if (int.parse(r['server_seq'] as String) > from ||
              rejected.contains(r['id']))
            r,
      ];
      seqs[t.name] = rows.values.fold(
        from,
        (m, r) => int.parse(r['server_seq'] as String) > m
            ? int.parse(r['server_seq'] as String)
            : m,
      );
    }
    return {
      'ok': true,
      'admin': admin,
      'me': me,
      'accepted': accepted,
      'denied': denied,
      'pulled': pulled,
      'seq': seqs,
    };
  }
}

SyncService device(FakeSheets sheets, {bool admin = false, String? token}) {
  final db = LocalDb.inMemory();
  db.setSetting(SyncService.urlKey, 'https://example.test/exec');
  db.setSetting(
    SyncService.tokenKey,
    token ?? (admin ? 'admin-secret' : 'secret'),
  );
  return SyncService(db)..transportFactory = (_) => sheets;
}

void main() {
  test('two devices see each other\'s flights after syncing', () async {
    final sheets = FakeSheets();
    final laptop = device(sheets);
    final phone = device(sheets, admin: true);

    final id = laptop.db.save(Tables.flights, {
      'date': '2026-10-28',
      'battery_pct': 45,
    });
    expect(laptop.pendingCount, 1);
    final first = await laptop.sync();
    expect(first!.pushed, 1);
    expect(laptop.pendingCount, 0);

    await phone.sync();
    expect(phone.db.byId(Tables.flights, id)!['battery_pct'], 45);

    phone.db.save(Tables.flights, {'id': id, 'notes': 'Strong wind'});
    await phone.sync();
    await laptop.sync();
    expect(laptop.db.byId(Tables.flights, id)!['notes'], 'Strong wind');
  });

  test('only the admin link may change and delete saved rows', () async {
    final sheets = FakeSheets();
    final pilot = device(sheets);
    final admin = device(sheets, admin: true);
    final id = pilot.db.save(Tables.flights, {'notes': 'first'});
    await pilot.sync();
    expect(pilot.isAdmin, isFalse);

    // An edit and a delete from the pilots' link are undone.
    pilot.db.save(Tables.flights, {'id': id, 'notes': 'changed'});
    final other = pilot.db.save(Tables.flights, {'notes': 'never sent'});
    pilot.db.delete(Tables.flights, other);
    await pilot.sync();
    expect(pilot.pendingCount, 0);
    expect(pilot.db.byId(Tables.flights, id)!['notes'], 'first');
    expect(pilot.db.byId(Tables.flights, other), isNull);
    expect(sheets.tables['flights']![id]!['notes'], 'first');
    expect(sheets.tables['flights']!.containsKey(other), isFalse);

    await admin.sync();
    expect(admin.isAdmin, isTrue);
    admin.db.delete(Tables.flights, id);
    await admin.sync();
    await pilot.sync();
    expect(pilot.db.rows(Tables.flights), isEmpty);
  });

  test('with an own link a person changes only their own entries', () async {
    final sheets = FakeSheets();
    final anna = device(sheets, token: 'anna-secret');
    final admin = device(sheets, admin: true);
    final others = admin.db.save(Tables.flights, {'notes': 'admin'});
    await admin.sync();

    await anna.sync();
    expect(anna.me, 'p-anna');
    final mine = anna.db.save(Tables.flights, {'notes': 'anna'});
    expect(anna.db.byId(Tables.flights, mine)!['created_by'], 'p-anna');
    expect(anna.canChange(anna.db.byId(Tables.flights, mine)!), isTrue);
    expect(anna.canChange(anna.db.byId(Tables.flights, others)!), isFalse);
    await anna.sync();

    anna.db.save(Tables.flights, {'id': mine, 'notes': 'fixed'});
    anna.db.delete(Tables.flights, others);
    await anna.sync();
    expect(sheets.tables['flights']![mine]!['notes'], 'fixed');
    expect(sheets.tables['flights']![others]!['deleted'], '0');
    expect(anna.db.byId(Tables.flights, others)!['deleted'], 0);
    expect(anna.pendingCount, 0);
  });

  test('a later sync only downloads what changed', () async {
    final sheets = FakeSheets();
    final a = device(sheets);
    a.db.save(Tables.projects, {'name': 'Horns Rev 2'});
    await a.sync();
    final second = await a.sync();
    expect(second!.pulled, 0);
  });

  test('offline changes stay queued and sync later', () async {
    final sheets = FakeSheets();
    final a = device(sheets);
    a.transportFactory = (_) => throw SyncException('offline');
    a.db.save(Tables.flights, {'notes': 'no signal'});
    expect(await a.sync(), isNull);
    expect(a.lastError, 'offline');
    expect(a.pendingCount, 1);

    a.transportFactory = (_) => sheets;
    await a.sync();
    expect(a.pendingCount, 0);
    expect(sheets.tables['flights']!.values.single['notes'], 'no signal');
  });

  test('a wrong token is reported and nothing is lost', () async {
    final sheets = FakeSheets();
    final a = device(sheets);
    a.db.setSetting(SyncService.tokenKey, 'wrong');
    a.db.save(Tables.flights, {'notes': 'x'});
    await a.sync();
    expect(a.lastError, isNotNull);
    expect(a.pendingCount, 1);
  });

  test('the connection link sets the URL and the token', () {
    final a = SyncService(LocalDb.inMemory());
    expect(a.setConnectionLink('hello'), isFalse);
    expect(
      a.setConnectionLink('https://script.google.com/macros/s/abc/exec'),
      isFalse,
    );
    expect(
      a.setConnectionLink(
        ' https://script.google.com/macros/s/abc/exec?key=t-1 ',
      ),
      isTrue,
    );
    expect(a.url, 'https://script.google.com/macros/s/abc/exec');
    expect(a.token, 't-1');
    expect(
      a.connectionLink,
      'https://script.google.com/macros/s/abc/exec?key=t-1',
    );
  });

  test('without settings sync does nothing', () async {
    final a = SyncService(LocalDb.inMemory());
    expect(await a.sync(), isNull);
  });
}
