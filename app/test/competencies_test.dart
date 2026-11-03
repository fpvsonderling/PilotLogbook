import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:pilot_logbook/data/competencies.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';
import 'package:pilot_logbook/main.dart';

String _inDays(int days) =>
    DateFormat('yyyy-MM-dd').format(DateTime.now().add(Duration(days: days)));

void main() {
  test('valid, expiring within 30 days, expired the day after', () {
    final today = DateTime(2026, 11, 3);
    Competency c(String expires) => Competency({'expires_on': expires});
    expect(c('').status(today), CompetencyStatus.valid);
    expect(c('').describe(today), 'No expiry');
    expect(c('2026-12-31').status(today), CompetencyStatus.valid);
    expect(c('2026-12-03').status(today), CompetencyStatus.expiring);
    expect(c('2026-11-13').describe(today), 'Expires in 10 days');
    expect(c('2026-11-03').status(today), CompetencyStatus.expiring);
    expect(c('2026-11-02').status(today), CompetencyStatus.expired);
    expect(c('2026-10-31').describe(today), 'Expired 3 days ago');
  });

  testWidgets('a pilot adds their own competency; it shows at the top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    final anna = db.save(Tables.people, {
      'name': 'Anna',
      'roles': 'pilot',
      'active': 1,
    });
    db.setSetting(LocalDb.meKey, anna);
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Competencies'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing added yet'), findsOneWidget);
    expect(find.byKey(const Key('alert-competencies')), findsNothing);

    await tester.tap(find.byKey(const Key('add-competency')));
    await tester.pumpAndSettle();
    // A pilot does not pick the person, nor verify.
    expect(find.byKey(const Key('competency-person')), findsNothing);
    expect(find.byKey(const Key('competency-verified')), findsNothing);
    await tester.tap(find.text('GWO'));
    await tester.enterText(find.byKey(const Key('competency-number')), 'W-1');
    await tester.enterText(
      find.byKey(const Key('competency-expires_on')),
      _inDays(10),
    );
    await tester.enterText(
      find.byKey(const Key('competency-url')),
      'https://drive.google.com/file/d/abc/view',
    );
    await tester.tap(find.byKey(const Key('save-competency')));
    await tester.pumpAndSettle();

    final row = db.rows(Tables.competencies).single;
    expect(row['person_id'], anna);
    expect(row['type'], 'GWO');
    expect(row['verified'], isNull);
    expect(find.text('Expires in 10 days'), findsOneWidget);
    expect(find.text('Open document'), findsOneWidget);
    expect(find.byKey(const Key('alert-competencies')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the admin verifies; an expired one warns on the flight form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.setSetting(SyncService.adminKey, '1');
    final anna = db.save(Tables.people, {
      'name': 'Anna',
      'roles': 'pilot',
      'active': 1,
    });
    db.save(Tables.people, {'name': 'Bob', 'roles': 'pilot', 'active': 1});
    db.save(Tables.competencies, {
      'person_id': anna,
      'type': 'Medical',
      'expires_on': _inDays(-2),
    });
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Competencies'));
    await tester.pumpAndSettle();
    // Every pilot is listed for the admin.
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Expired 2 days ago'), findsOneWidget);

    await tester.tap(find.text('Medical').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('competency-verified')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-competency')));
    await tester.pumpAndSettle();
    expect(db.rows(Tables.competencies).single['verified'], 1);
    expect(find.text('Verified'), findsOneWidget);

    await tester.tap(find.text('Cargo LogBook'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Anna').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Expired: Medical'), findsOneWidget);
  });

  test(
    'a key that is not the admin\'s keeps only its own competencies',
    () async {
      final db = LocalDb.inMemory();
      db.setSetting(SyncService.urlKey, 'https://example.test/exec');
      db.setSetting(SyncService.tokenKey, 'x');
      var admin = true;
      final sync = SyncService(db)
        ..transportFactory = (_) => _Answer(
          () => {
            'ok': true,
            'admin': admin,
            'me': 'p-anna',
            'accepted': {},
            'denied': {},
            'pulled': {
              'competencies': [
                {
                  'id': 'c1',
                  'updated_at': 't1',
                  'server_seq': 1,
                  'deleted': 0,
                  'person_id': 'p-anna',
                },
                {
                  'id': 'c2',
                  'updated_at': 't1',
                  'server_seq': 2,
                  'deleted': 0,
                  'person_id': 'p-bob',
                },
              ],
            },
            'seq': {'competencies': 2},
          },
        );
      await sync.sync();
      expect(db.rows(Tables.competencies).length, 2);
      admin = false;
      await sync.sync();
      expect([for (final r in db.rows(Tables.competencies)) r['id']], ['c1']);
    },
  );
}

class _Answer implements SyncTransport {
  _Answer(this.answer);
  final Map<String, Object?> Function() answer;

  @override
  Future<Map<String, Object?>> call(Map<String, Object?> body) async {
    final a = answer();
    // A non-admin answer carries only the person's own.
    if (a['admin'] != true) {
      final pulled = a['pulled'] as Map;
      a['pulled'] = {
        'competencies': [
          for (final r in pulled['competencies'] as List)
            if ((r as Map)['person_id'] == 'p-anna') r,
        ],
      };
    }
    return a;
  }
}
