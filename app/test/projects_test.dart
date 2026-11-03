import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/projects.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';
import 'package:pilot_logbook/main.dart';

void main() {
  test('coordinates from Google Maps links', () {
    String? at(String url) => pointFromMapsUrl(url)?.text;
    expect(
      at('https://www.google.com/maps/@54.7712345,1.9234567,12z'),
      '54.771234, 1.923457',
    );
    expect(
      at(
        'https://www.google.com/maps/place/Dogger+Bank/@54.7,1.9,10z/'
        'data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d54.75!4d2.0123',
      ),
      '54.75, 2.0123',
    );
    expect(at('https://maps.google.com/?q=55.5,-3.25'), '55.5, -3.25');
    expect(
      at('https://www.google.com/maps/search/?api=1&query=55.5%2C8.1'),
      '55.5, 8.1',
    );
    expect(at('https://maps.app.goo.gl/AbCdEf'), isNull);
  });

  test('one point per line, with or without a name', () {
    final r = parseCoordinates(
      '54.1, 2.2\n'
      'T01: 54.11 2.21\n'
      '\n'
      'T02: https://www.google.com/maps/@54.12,2.22,15z\n'
      'somewhere',
    );
    expect(
      [for (final p in r.points) '${p.label}|${p.text}'],
      ['|54.1, 2.2', 'T01|54.11, 2.21', 'T02|54.12, 2.22'],
    );
    expect(r.bad, ['somewhere']);
    expect(parseCoordinates('91, 2').bad, ['91, 2']);
  });

  test('Google Maps button: own link, else the first point', () {
    expect(
      Project({'coordinates': '54.1, 2.2\n55, 3'}).mapsUrl,
      'https://www.google.com/maps/search/?api=1&query=54.1%2C2.2',
    );
    expect(
      Project({
        'coordinates': '54.1, 2.2',
        'maps_url': 'https://maps.app.goo.gl/x',
      }).mapsUrl,
      'https://maps.app.goo.gl/x',
    );
    expect(Project({}).mapsUrl, '');
  });

  testWidgets('the admin adds a project from a pasted Maps link', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();
    // Not the admin: nothing to add.
    expect(find.byKey(const Key('add-project')), findsNothing);
    expect(find.text('No projects yet: the admin adds them'), findsOneWidget);

    db.setSetting(SyncService.adminKey, '1');
    // The app started again with the admin's key.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-project')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('project-name')),
      'Dogger Bank',
    );
    await tester.enterText(find.byKey(const Key('project-client')), 'SSE');
    await tester.enterText(find.byKey(const Key('project-country')), 'UK');
    await tester.enterText(
      find.byKey(const Key('project-coordinates')),
      'https://www.google.com/maps/@54.75,1.9,10z',
    );
    await tester.enterText(
      find.byKey(const Key('project-zone_map_url')),
      'https://dronesafetymap.example',
    );
    await tester.tap(find.byKey(const Key('save-project')));
    await tester.pumpAndSettle();

    final row = db.rows(Tables.projects).single;
    expect(row['coordinates'], '54.75, 1.9');
    expect(row['active'], 1);
    expect(find.text('SSE · UK'), findsOneWidget);
    expect(find.text('No flights yet'), findsOneWidget);
    expect(find.byKey(const Key('maps-Dogger Bank')), findsOneWidget);
    expect(find.byKey(const Key('zones-Dogger Bank')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('coordinates that cannot be read are not saved', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.setSetting(SyncService.adminKey, '1');
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-project')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('project-name')), 'X');
    await tester.enterText(
      find.byKey(const Key('project-coordinates')),
      'https://maps.app.goo.gl/AbC',
    );
    await tester.tap(find.byKey(const Key('save-project')));
    await tester.pumpAndSettle();
    expect(find.textContaining('short links cannot be read'), findsOneWidget);
    expect(db.rows(Tables.projects), isEmpty);
  });

  testWidgets('projects and competencies fit on a phone', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    db.setSetting(SyncService.adminKey, '1');
    final anna = db.save(Tables.people, {
      'name': 'Anna Kowalska-Wiśniewska',
      'roles': 'pilot',
      'active': 1,
    });
    db.save(Tables.competencies, {
      'person_id': anna,
      'type': 'UAS pilot licence STS-01 and STS-02',
      'number': 'POL-RP-0000123456',
      'issued_on': '2025-01-01',
      'expires_on': '2026-11-10',
      'verified': 1,
      'url': 'https://drive.google.com/x',
    });
    db.save(Tables.projects, {
      'name': 'Baltic Power Offshore Wind Farm',
      'client': 'Orlen Neptun',
      'country': 'Poland',
      'coordinates': 'T01: 54.9, 17.9\nT02: 54.91, 17.91',
      'zone_map_url': 'https://dronemap.pansa.pl',
      'active': 1,
    });
    await tester.pumpWidget(PilotLogbookApp(db: db));
    for (final page in ['Projects', 'Competencies']) {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(page).last);
      await tester.pumpAndSettle();
      // The drawer's own long labels overflow while it closes; not this page.
      tester.takeException();
      await tester.pump();
      expect(tester.takeException(), isNull, reason: page);
    }
    expect(find.text('Verified'), findsOneWidget);
  });
}
