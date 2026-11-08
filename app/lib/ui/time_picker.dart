import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// "HH:mm:ss" for seconds since midnight.
String formatTimeOfDay(int seconds) {
  String two(int v) => v.toString().padLeft(2, '0');
  final s = seconds % (24 * 3600);
  return '${two(s ~/ 3600)}:${two((s % 3600) ~/ 60)}:${two(s % 60)}';
}

/// A clock with hour, minute and second wheels. Flutter's own time picker
/// has no seconds, which flight times need. Returns seconds since midnight,
/// or null when cancelled.
Future<int?> showSecondsTimePicker(
  BuildContext context, {
  required String title,
  required int initial,
}) => showDialog<int>(
  context: context,
  builder: (_) => _SecondsTimePicker(title: title, initial: initial),
);

class _SecondsTimePicker extends StatefulWidget {
  const _SecondsTimePicker({required this.title, required this.initial});

  final String title;
  final int initial;

  @override
  State<_SecondsTimePicker> createState() => _SecondsTimePickerState();
}

class _SecondsTimePickerState extends State<_SecondsTimePicker> {
  late int _h = widget.initial ~/ 3600 % 24;
  late int _m = widget.initial % 3600 ~/ 60;
  late int _s = widget.initial % 60;
  late final _hc = FixedExtentScrollController(initialItem: _h);
  late final _mc = FixedExtentScrollController(initialItem: _m);
  late final _sc = FixedExtentScrollController(initialItem: _s);

  @override
  void dispose() {
    _hc.dispose();
    _mc.dispose();
    _sc.dispose();
    super.dispose();
  }

  void _now() {
    final n = DateTime.now();
    for (final (c, v) in [(_hc, n.hour), (_mc, n.minute), (_sc, n.second)]) {
      // Wheels loop, so jump to the nearest copy of the value.
      final cur = c.selectedItem;
      final count = c == _hc ? 24 : 60;
      final base = cur - cur % count;
      c.jumpToItem(base + v);
    }
    setState(() {
      _h = n.hour;
      _m = n.minute;
      _s = n.second;
    });
  }

  Widget _wheel(
    String key,
    FixedExtentScrollController c,
    int count,
    ValueChanged<int> onChanged,
  ) => SizedBox(
    width: 64,
    child: CupertinoPicker(
      key: ValueKey('time-$key'),
      scrollController: c,
      itemExtent: 40,
      squeeze: 1.1,
      looping: true,
      onSelectedItemChanged: (i) => setState(() => onChanged(i % count)),
      children: [
        for (var i = 0; i < count; i++)
          Center(
            child: Text(
              i.toString().padLeft(2, '0'),
              // The app's own font; the wheel would use the iPhone one.
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget colon() => Text(':', style: theme.textTheme.headlineSmall);
    return AlertDialog(
      title: Text(widget.title),
      content: ScrollConfiguration(
        // Let a mouse drag the wheels on Windows and macOS too.
        behavior: ScrollConfiguration.of(context)
            .copyWith(dragDevices: PointerDeviceKind.values.toSet()),
        child: SizedBox(
          height: 200,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _wheel('h', _hc, 24, (v) => _h = v),
              colon(),
              _wheel('m', _mc, 60, (v) => _m = v),
              colon(),
              _wheel('s', _sc, 60, (v) => _s = v),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _now, child: const Text('Now')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _h * 3600 + _m * 60 + _s),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
