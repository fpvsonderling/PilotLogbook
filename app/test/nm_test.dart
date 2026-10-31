import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/main.dart';
import 'package:pilot_logbook/ui/nm_page.dart';

void main() {
  testWidgets('Nm shows the FB3 values until the sheet has its own', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Nm'));
    await tester.pumpAndSettle();
    expect(find.text('M8 hook'), findsOneWidget);
    expect(find.text('6 Nm'), findsOneWidget);
    expect(find.text('2,5 Nm'), findsNWidgets(2));
    expect(find.text('more or less 1 Nm'), findsOneWidget);
    // Read only: nothing to add, nothing to tap.
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(
      find.descendant(of: find.byType(NmPage), matching: find.byType(InkWell)),
      findsNothing,
    );

    db.save(Tables.torqueSpecs, {
      'model': 'M30T',
      'component': 'Arms',
      'value_nm': 0.8,
    });
    db.changes.notify();
    await tester.pumpAndSettle();
    expect(find.text('M30T · Arms'), findsOneWidget);
    expect(find.text('0,8 Nm'), findsOneWidget);
    expect(find.text('M8 hook'), findsNothing);
  });
}
