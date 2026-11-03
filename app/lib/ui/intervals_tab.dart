import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/maintenance.dart';
import '../data/schema.dart';
import 'services.dart';

/// How often each maintenance assembly is due, for every drone and per
/// drone model. The maintenance book's values apply until the admin
/// changes them; everyone else only reads.
class IntervalsTab extends StatelessWidget {
  const IntervalsTab({super.key});

  @override
  Widget build(BuildContext context) => DbBuilder(
    builder: (context) {
      final services = Services.of(context);
      final db = services.db;
      final log = MaintenanceLog(db);
      final rows = db.rows(Tables.maintenanceIntervals);
      final models = {
        for (final a in db.rows(Tables.aircraft))
          if ((a['model'] as String? ?? '').trim().isNotEmpty)
            (a['model'] as String).trim(),
      }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      DbRow? rowFor(String model, String section) => rows
          .where(
            (r) =>
                (r['model'] as String? ?? '').trim().toLowerCase() ==
                    model.toLowerCase() &&
                r['section'] == section,
          )
          .lastOrNull;
      final theme = Theme.of(context);
      return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Due after the hours, flights or days since the assembly was '
              'last checked, whichever comes first; yellow from 80 %. '
              'Defaults from the FB3 maintenance book (Maintenance Planning '
              'Document).${services.isAdmin ? ' Tap one to change it.' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (final model in ['', ...models]) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                model.isEmpty ? 'All drones' : 'Model $model',
                style: theme.textTheme.titleMedium,
              ),
            ),
            for (final s in maintenanceSections)
              () {
                final own = rowFor(model, s.column);
                final interval = log.interval(s.column, model: model);
                final from = own != null
                    ? 'set here'
                    : model.isNotEmpty && rowFor('', s.column) != null
                    ? 'as all drones'
                    : 'maintenance book';
                return ListTile(
                  key: Key('interval-$model-${s.column}'),
                  dense: true,
                  title: Text(s.title),
                  subtitle: Text('${interval.describe()} · $from'),
                  onTap: services.isAdmin
                      ? () => _edit(context, model, s, own, interval)
                      : null,
                );
              }(),
          ],
        ],
      );
    },
  );

  Future<void> _edit(
    BuildContext context,
    String model,
    MaintenanceSection section,
    DbRow? own,
    MaintenanceInterval now,
  ) async {
    final services = Services.of(context);
    String n(num? v) => v == null
        ? ''
        : v == v.roundToDouble()
        ? '${v.round()}'
        : '$v';
    final hours = TextEditingController(text: n(now.hours));
    final flights = TextEditingController(text: n(now.flights));
    final days = TextEditingController(text: n(now.days));
    Widget field(String label, TextEditingController c, String key) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: Key('interval-$key'),
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      ),
    );
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text(
          '${section.title} · ${model.isEmpty ? 'all drones' : model}',
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              field('Every … flight hours', hours, 'hours'),
              field('Every … flights', flights, 'flights'),
              field('Every … days', days, 'days'),
              const Text(
                'Whichever comes first. All three empty: no reminder for '
                'this assembly.',
              ),
            ],
          ),
        ),
        actions: [
          if (own != null)
            TextButton(
              key: const Key('interval-reset'),
              onPressed: () => Navigator.pop(context, 'reset'),
              child: Text(model.isEmpty ? 'Book value' : 'As all drones'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('interval-save'),
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (action == 'save') {
      double? real(String t) => double.tryParse(t.trim().replaceAll(',', '.'));
      services.db.save(Tables.maintenanceIntervals, {
        if (own != null) 'id': own['id'],
        'model': model,
        'section': section.column,
        'hours': real(hours.text),
        'flights': real(flights.text)?.round(),
        'days': real(days.text)?.round(),
      });
      services.sync.sync();
    } else if (action == 'reset' && own != null) {
      services.db.delete(Tables.maintenanceIntervals, own['id'] as String);
      services.sync.sync();
    }
  }
}
