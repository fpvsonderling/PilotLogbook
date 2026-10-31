import 'package:flutter/material.dart';

import '../data/schema.dart';
import 'services.dart';

/// Bolt torque values, only to look up. They come from the torque_specs tab
/// in Google Sheets; until that tab has rows, the FB3 values below are shown.
class NmPage extends StatelessWidget {
  const NmPage({super.key});

  /// (component, value in Nm, notes), as in the old AppSheet "Nm" table.
  static const defaults = [
    ('M3', 1.0, 'more or less'),
    ('M4 props', 2.5, ''),
    ('M6 motor mounts', 2.0, ''),
    ('M6 load structure close to hook and centre plate frame', 2.5, ''),
    ('M5 centre plate top and side + landing gear', 1.5, ''),
    ('M8 hook', 6.0, ''),
  ];

  static String formatNm(Object? value) {
    final n = value is num ? value : num.tryParse('${value ?? ''}');
    if (n == null) return '';
    final text = n == n.roundToDouble()
        ? n.toInt().toString()
        : n.toString().replaceAll('.', ',');
    return '$text Nm';
  }

  @override
  Widget build(BuildContext context) {
    final db = Services.of(context).db;
    return DbBuilder(
      builder: (context) {
        final saved = db.rows(
          Tables.torqueSpecs,
          orderBy: 'model COLLATE NOCASE, rowid',
        );
        final rows = saved.isEmpty
            ? [
                for (final (component, nm, notes) in defaults)
                  (component, nm, notes),
              ]
            : [
                for (final r in saved)
                  (
                    [
                      if ((r['model'] as String? ?? '').isNotEmpty) r['model'],
                      r['component'] ?? '',
                    ].join(' · '),
                    r['value_nm'],
                    r['notes'] as String? ?? '',
                  ),
              ];
        final theme = Theme.of(context);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Nm', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Table(
                columnWidths: const {
                  0: FlexColumnWidth(3),
                  1: FlexColumnWidth(1),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                    children: [
                      for (final h in ['Title', 'Nm'])
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(h, style: theme.textTheme.titleSmall),
                        ),
                    ],
                  ),
                  for (final (i, (title, nm, notes)) in rows.indexed)
                    TableRow(
                      decoration: i.isOdd
                          ? BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLow,
                            )
                          : null,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(title),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            [
                              if (notes.isNotEmpty) notes,
                              formatNm(nm),
                            ].join(' '),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
