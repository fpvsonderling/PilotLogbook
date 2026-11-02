import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/main.dart';
import 'package:pilot_logbook/ui/theme.dart';

void main() {
  testWidgets('Settings switches to the dark theme and remembers it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = LocalDb.inMemory();
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.tap(find.text('Settings').first);
    await tester.pumpAndSettle();

    Brightness brightness() =>
        Theme.of(tester.element(find.byKey(const Key('about')))).brightness;
    expect(brightness(), Brightness.light);
    expect(find.text('Author: Pavlo Yavorskyi'), findsOneWidget);
    expect(find.text('Co-author: Claude (Anthropic)'), findsOneWidget);

    final dark = find.text('Dark');
    await tester.ensureVisible(dark);
    await tester.tap(dark);
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.dark);
    expect(db.setting(ThemeChoice.settingsKey), 'dark');

    // A fresh start of the app opens in dark.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(PilotLogbookApp(db: db));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });

  test('stored theme values', () {
    expect(ThemeChoice.parse(null), ThemeMode.light);
    expect(ThemeChoice.parse('dark'), ThemeMode.dark);
    expect(ThemeChoice.parse('system'), ThemeMode.system);
    expect(AppTheme.dark().colorScheme.brightness, Brightness.dark);
  });
}
