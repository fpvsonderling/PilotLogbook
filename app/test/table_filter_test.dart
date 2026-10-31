import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/table_filter.dart';
import 'package:pilot_logbook/data/table_pdf.dart';
import 'package:pilot_logbook/main.dart';

void main() {
  final rows = [
    {
      'date': '2026-09-30',
      'drone': 'a',
      'rp': 'p1',
      'pa': 'p2',
      'note': 'Fiona pickup',
    },
    {
      'date': '2026-10-01',
      'drone': 'b',
      'rp': 'p2',
      'pa': null,
      'note': 'Inspection blade',
    },
    {
      'date': '2026-10-31',
      'drone': 'a',
      'rp': 'p3',
      'pa': 'p1',
      'note': 'Cargo drop',
    },
  ];
  final fields = <FilterField<Map<String, String?>>>[
    FilterField('drone', 'Drone', (r) => [r['drone']]),
    FilterField('pilot', 'Pilot', (r) => [r['rp'], r['pa']]),
  ];
  final columns = <TableColumn<Map<String, String?>>>[
    TableColumn('Date', 1, (r) => r['date']!),
    TableColumn('Note', 1, (r) => r['note']!),
  ];
  List<String> dates(TableFilter f) => [
    for (final r in f.apply(
      rows,
      date: (r) => r['date']!,
      fields: fields,
      columns: columns,
    ))
      r['date']!,
  ];

  test('no filter keeps every row', () {
    expect(dates(const TableFilter()), hasLength(3));
    expect(const TableFilter().isEmpty, isTrue);
  });

  test('a date range includes both ends', () {
    expect(dates(const TableFilter().withDates('2026-10-01', '2026-10-31')), [
      '2026-10-01',
      '2026-10-31',
    ]);
    expect(dates(const TableFilter(from: '2026-10-02')), ['2026-10-31']);
  });

  test('a field matches any of its values, fields add up', () {
    final pilot = const TableFilter().withChoice('pilot', 'p1');
    expect(dates(pilot), ['2026-09-30', '2026-10-31']);
    expect(dates(pilot.withChoice('drone', 'b')), isEmpty);
    expect(pilot.withChoice('pilot', null).isEmpty, isTrue);
  });

  test('search needs every word, in any column, any case', () {
    expect(dates(const TableFilter(text: 'fiona')), ['2026-09-30']);
    expect(dates(const TableFilter(text: '10-31 cargo')), ['2026-10-31']);
    expect(dates(const TableFilter(text: 'cargo fiona')), isEmpty);
  });

  test('options are only the values rows have, sorted by name', () {
    expect(filterOptions(rows, fields[1], {'p1': 'Zoe', 'p2': 'Adam'}), {
      'p2': 'Adam',
      'p3': 'p3',
      'p1': 'Zoe',
    });
  });

  test('describe names what was picked', () {
    final f = const TableFilter(
      from: '2026-10-01',
      text: 'drop',
    ).withChoice('drone', 'a');
    expect(
      f.describe(fields, (key, v) => v == 'a' ? '18' : v),
      '2026-10-01 – … · Drone: 18 · "drop"',
    );
  });

  test('the PDF has a page per ~30 rows', () async {
    ByteData font(String name) =>
        ByteData.sublistView(File('assets/fonts/$name.ttf').readAsBytesSync());
    final many = [for (var i = 0; i < 200; i++) ...rows];
    final bytes = await tablePdf(
      title: 'Cargo LogBook',
      columns: columns,
      rows: many,
      filters: 'Drone: 18',
      summary: ['600 flights'],
      regular: font('Barlow-Regular'),
      bold: font('Barlow-SemiBold'),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final pages = RegExp(r'/Type\s*/Page[^s]')
        .allMatches(String.fromCharCodes(bytes))
        .length;
    expect(pages, greaterThan(5));
  });

  testWidgets('filtering the flights by drone and by text', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    final d18 = db.save(Tables.aircraft, {'name': '18', 'active': 1});
    final d24 = db.save(Tables.aircraft, {'name': '24', 'active': 1});
    for (final (date, drone, notes) in [
      ('2026-10-01', d18, 'wind 8 m/s'),
      ('2026-10-02', d24, 'rain'),
      ('2026-10-03', d18, 'calm'),
    ]) {
      db.save(Tables.flights, {
        'date': date,
        'kind': 'cargo',
        'aircraft_id': drone,
        'duration_s': 60,
        'notes': notes,
      });
    }
    await tester.pumpWidget(PilotLogbookApp(db: db));
    expect(find.text('Cargo LogBook · 3 flights'), findsOneWidget);

    await tester.tap(find.byKey(const Key('filter-drone')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '18'));
    await tester.pumpAndSettle();
    expect(
      find.text('Cargo LogBook · 2 of 3 flights · 0:02:00'),
      findsOneWidget,
    );
    expect(find.text('Drone: 18'), findsOneWidget);
    expect(find.text('rain'), findsNothing);

    await tester.enterText(find.byKey(const Key('filter-search')), 'calm');
    await tester.pumpAndSettle();
    expect(
      find.text('Cargo LogBook · 1 of 3 flights · 0:01:00'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('filter-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Cargo LogBook · 3 flights'), findsOneWidget);
    expect(find.byKey(const Key('export-pdf')), findsOneWidget);
  });
}
