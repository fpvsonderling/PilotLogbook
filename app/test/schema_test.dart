import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pilot_logbook/data/schema.dart';

/// The Apps Script must create exactly the columns the app syncs.
void main() {
  test('Code.gs SCHEMA matches schema.dart', () {
    final code = File('../apps_script/Code.gs').readAsStringSync();
    final block = code.substring(
      code.indexOf('// SCHEMA-START'),
      code.indexOf('// SCHEMA-END'),
    );
    final script = {
      for (final m in RegExp(
        r'^\s+(\w+): \[(.*)\],$',
        multiLine: true,
      ).allMatches(block))
        m[1]!: [for (final c in RegExp(r"'(\w+)'").allMatches(m[2]!)) c[1]!],
    };
    expect(script, {
      for (final t in Tables.all) t.name: [for (final c in t.columns) c.name],
    });
  });
}
