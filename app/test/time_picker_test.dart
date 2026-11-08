import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/ui/time_picker.dart';

void main() {
  test('formatTimeOfDay pads hours, minutes and seconds', () {
    expect(formatTimeOfDay(0), '00:00:00');
    expect(formatTimeOfDay(13 * 3600 + 3 * 60 + 30), '13:03:30');
    expect(formatTimeOfDay(24 * 3600 + 5), '00:00:05');
  });

  Future<int? Function()> open(WidgetTester tester, int initial) async {
    int? result;
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showSecondsTimePicker(
                context,
                title: 'Land',
                initial: initial,
              );
              done = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    return () => done ? result : -1;
  }

  testWidgets('wheels pick hours, minutes and seconds', (tester) async {
    final read = await open(tester, 13 * 3600);
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Land'), findsOneWidget);

    // Three rows down on minutes and twelve on seconds: 13:03:12.
    await tester.drag(
      find.byKey(const ValueKey('time-m')),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('time-s')),
      const Offset(0, -480),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(read(), 13 * 3600 + 3 * 60 + 12);
  });

  testWidgets('cancel returns nothing', (tester) async {
    final read = await open(tester, 0);
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(read(), null);
  });
}
