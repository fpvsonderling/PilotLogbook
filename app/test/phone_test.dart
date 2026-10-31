import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/checklists.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/main.dart';
import 'package:pilot_logbook/ui/daily_check_screen.dart';

/// The same screens on a phone held upright (Android).
void main() {
  // The real fonts, so text is as wide as on the phone (tests otherwise
  // draw every letter as a square box).
  setUpAll(() async {
    for (final (family, files) in [
      ('Barlow', ['Regular', 'Medium', 'SemiBold', 'Bold']),
      ('Barlow Condensed', ['SemiBold', 'Bold']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        final name = family.replaceAll(' ', '');
        final bytes = File('assets/fonts/$name-$f.ttf').readAsBytesSync();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
  }

  Future<void> open(WidgetTester tester, String page) async {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(page));
    await tester.pumpAndSettle();
  }

  testWidgets('flights show as cards and the form fills the screen', (
    tester,
  ) async {
    phone(tester);
    final db = LocalDb.inMemory();
    db.save(Tables.projects, {'name': 'Horns Rev 2', 'active': 1});
    db.save(Tables.aircraft, {'name': '19', 'active': 1});
    db.save(Tables.batteries, {'name': '7', 'active': 1});
    db.save(Tables.missionTypes, {'name': 'Inspection', 'active': 1});
    db.save(Tables.people, {'name': 'Pavlo', 'roles': 'pilot', 'active': 1});

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    await tester.tap(find.text('Horns Rev 2'));
    await tester.tap(find.text('19'));
    await tester.tap(find.text('7'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Take off'),
      '10:00:00',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Land'),
      '10:12:00',
    );
    final what = find.widgetWithText(FilterChip, 'Inspection');
    await tester.ensureVisible(what);
    await tester.pumpAndSettle();
    await tester.tap(what);
    await tester.pumpAndSettle();
    final rp = find.widgetWithText(DropdownButtonFormField<String?>, 'RP');
    await tester.ensureVisible(rp);
    await tester.pumpAndSettle();
    await tester.tap(rp);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pavlo').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save-flight')));
    await tester.pumpAndSettle();

    expect(db.rows(Tables.flights), hasLength(1));
    expect(find.text('Drone 19 · Horns Rev 2'), findsOneWidget);
    expect(find.text('0:12:00'), findsOneWidget);
  });

  testWidgets('a daily check is done and saved on a phone', (tester) async {
    phone(tester);
    final db = LocalDb.inMemory();
    db.save(Tables.aircraft, {'name': '24', 'active': 1});
    db.save(Tables.people, {'name': 'Pavlo', 'roles': 'pilot', 'active': 1});

    await tester.pumpWidget(PilotLogbookApp(db: db));
    await open(tester, 'Daily checks');
    await tester.tap(find.text('New daily check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pavlo'));
    await tester.tap(find.text('24'));
    await tester.pumpAndSettle();

    final list = find
        .descendant(
          of: find.byType(DailyCheckScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    for (final s in fb3Checklist.sections) {
      await tester.scrollUntilVisible(
        find.text(s.title),
        200,
        scrollable: list,
      );
      final button = find.descendant(
        of: find.ancestor(of: find.text(s.title), matching: find.byType(Card)),
        matching: find.text('OK'),
      );
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button.last);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('save-check')));
    await tester.pumpAndSettle();
    expect(find.text('Ready to fly'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-save-check')));
    await tester.pumpAndSettle();
    expect(db.rows(Tables.dailyChecksFb3).single['storage'], 'Ok');
  });

  testWidgets('Statistic fills the phone width with two tiles a row', (
    tester,
  ) async {
    phone(tester);
    final db = LocalDb.inMemory();
    final project = db.save(Tables.projects, {'name': 'Statkraft'});
    final pavlo = db.save(Tables.people, {'name': 'Pavlo', 'roles': 'pilot'});
    for (final (date, aborted) in [
      ('2026-09-30', 0),
      ('2026-10-01', 1),
      ('2026-10-02', 0),
    ]) {
      db.save(Tables.flights, {
        'date': date,
        'kind': 'cargo',
        'project_id': project,
        'rp_id': pavlo,
        'duration_s': 300,
        'aborted': aborted,
      });
    }
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await open(tester, 'Statistic');
    expect(tester.takeException(), isNull);

    final flights = tester.getRect(
      find.ancestor(
        of: find.text('Flights').first,
        matching: find.byType(Card),
      ),
    );
    final time = tester.getRect(
      find.ancestor(of: find.text('Flight time'), matching: find.byType(Card)),
    );
    final screen =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    // Side by side, together nearly the full width.
    expect(time.top, flights.top);
    expect(time.right, greaterThan(screen - 20));
    expect(flights.width, greaterThan(screen / 2 - 20));

    expect(find.byKey(const Key('export-pdf')), findsOneWidget);
    expect(find.byKey(const Key('filter-project')), findsOneWidget);
    expect(find.byKey(const Key('filter-search')), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Last 12 months'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .last,
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('1 aborted', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
