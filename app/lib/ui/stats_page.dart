import 'package:flutter/material.dart';

import '../data/logbook.dart';
import 'services.dart';
import 'theme.dart';

/// Counted from the flights themselves, so it is never out of date.
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    return DbBuilder(
      builder: (context) {
        final totals = logbook.totals();
        final all = totals.all;
        final months = logbook.monthStats().take(12).toList();
        final problem = Theme.of(context).extension<CheckColors>()!.problem;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Tile('Flights', '${all.flights}'),
                _Tile('Flight time', formatDuration(all.seconds)),
                _Tile(
                  'Aborted missions',
                  '${all.aborted}',
                  note: _share(all.aborted, all.flights),
                  color: all.aborted > 0 ? problem : null,
                ),
                _Tile(
                  'Near misses',
                  '${all.nearMisses}',
                  note: _share(all.nearMisses, all.flights),
                  color: all.nearMisses > 0 ? problem : null,
                ),
                _Tile(
                  'Flying days',
                  '${totals.days}',
                  note: totals.firstDate == null
                      ? null
                      : '${totals.firstDate} – ${totals.lastDate}',
                ),
                _Tile(
                  'Flights per day',
                  totals.days == 0
                      ? '–'
                      : (all.flights / totals.days).toStringAsFixed(1),
                ),
                _Tile('Average flight', formatDuration(all.averageSeconds)),
                _Tile('Longest flight', formatDuration(totals.longestSeconds)),
              ],
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 24,
              runSpacing: 24,
              children: [
                _StatTable('Projects', logbook.projectStats(), total: true),
                _StatTable('Pilots (as RP)', logbook.pilotStats(), total: true),
                _StatTable('Drones', logbook.droneStats(), total: true),
                _StatTable('Cargo / Inspection', [
                  for (final k in logbook.kindStats())
                    FlightStat(
                      k.id,
                      _capitalize(k.name),
                      flights: k.flights,
                      seconds: k.seconds,
                      aborted: k.aborted,
                      nearMisses: k.nearMisses,
                    ),
                ]),
                _StatTable('Last 12 months', months, bars: true),
                _StatTable(
                  'Spotters',
                  logbook.spotterStats(),
                  time: false,
                  safety: false,
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  static String? _share(int n, int of) => of == 0 || n == 0
      ? null
      : '${(100 * n / of).toStringAsFixed(1)}% of flights';

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// One big number.
class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {this.note, this.color});
  final String label;
  final String value;
  final String? note;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 160,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
              if (note != null)
                Text(
                  note!,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Flights, time, aborted missions and near misses per group, with a
/// total row when [total] is set.
class _StatTable extends StatelessWidget {
  const _StatTable(
    this.title,
    this.rows, {
    this.total = false,
    this.time = true,
    this.safety = true,
    this.bars = false,
  });

  final String title;
  final List<FlightStat> rows;
  final bool total;
  final bool time;
  final bool safety;

  /// A bar after the flight count, longest for the busiest row.
  final bool bars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final most = rows.fold(0, (n, r) => r.flights > n ? r.flights : n);
    const bold = TextStyle(fontWeight: FontWeight.bold);
    List<DataCell> cells(FlightStat r, {TextStyle? style}) => [
      DataCell(Text(r.name, style: style)),
      DataCell(Text('${r.flights}', style: style)),
      if (bars)
        DataCell(
          SizedBox(
            width: 120,
            height: 10,
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: most == 0 ? 0 : r.flights / most,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      if (time) DataCell(Text(formatDuration(r.seconds), style: style)),
      if (safety) ...[
        DataCell(Text(r.aborted == 0 ? '' : '${r.aborted}', style: style)),
        DataCell(
          Text(r.nearMisses == 0 ? '' : '${r.nearMisses}', style: style),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: theme.textTheme.titleMedium),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 24,
            columns: [
              const DataColumn(label: Text('Name')),
              const DataColumn(label: Text('Flights'), numeric: true),
              if (bars) const DataColumn(label: Text('')),
              if (time) const DataColumn(label: Text('Time'), numeric: true),
              if (safety) ...const [
                DataColumn(label: Text('Aborted'), numeric: true),
                DataColumn(label: Text('Near miss'), numeric: true),
              ],
            ],
            rows: [
              for (final r in rows) DataRow(cells: cells(r)),
              if (total && rows.length > 1)
                DataRow(
                  cells: cells(
                    FlightStat(
                      '',
                      'Total',
                      flights: rows.fold(0, (n, r) => n + r.flights),
                      seconds: rows.fold(0, (n, r) => n + r.seconds),
                      aborted: rows.fold(0, (n, r) => n + r.aborted),
                      nearMisses: rows.fold(0, (n, r) => n + r.nearMisses),
                    ),
                    style: bold,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
