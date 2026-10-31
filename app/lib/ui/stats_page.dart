import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import '../data/stats_pdf.dart';
import '../data/table_filter.dart';
import 'services.dart';
import 'table_tools.dart';
import 'theme.dart';

/// Counted from the flights themselves, so it is never out of date. The
/// filters narrow every figure to some dates, a project, a drone, a person
/// or cargo / inspection, and PDF exports what is shown.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  var _filter = const TableFilter();

  static const _kinds = {'cargo': 'Cargo', 'inspection': 'Inspection'};

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    return DbBuilder(
      builder: (context) {
        final all = logbook.flights();
        final labels = {
          'project': logbook.names(Tables.projects),
          'drone': logbook.names(Tables.aircraft),
          'pilot': logbook.names(Tables.people),
          'kind': _kinds,
        };
        final f = _filter;
        final totals = logbook.totals(f);
        final figures = _figures(totals);
        final sections = [
          StatsSection('Projects', logbook.projectStats(f), total: true),
          StatsSection('Pilots (as RP)', logbook.pilotStats(f), total: true),
          StatsSection('Drones', logbook.droneStats(f), total: true),
          StatsSection('Cargo / Inspection', [
            for (final k in logbook.kindStats(f))
              FlightStat(
                k.id,
                _kinds[k.name] ?? _capitalize(k.name),
                flights: k.flights,
                seconds: k.seconds,
                aborted: k.aborted,
                nearMisses: k.nearMisses,
              ),
          ]),
          StatsSection(
            'Last 12 months',
            logbook.monthStats(f).take(12).toList(),
            bars: true,
          ),
          StatsSection(
            'Spotters',
            logbook.spotterStats(f),
            time: false,
            safety: false,
          ),
        ];
        final describe = f.describe<DbRow>(
          Logbook.statsFields,
          (key, v) => labels[key]?[v] ?? v,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            if (all.isNotEmpty)
              Builder(
                // Its own context, so the share sheet opens by the button.
                builder: (context) => FilterBar<DbRow>(
                  rows: all,
                  fields: Logbook.statsFields,
                  labels: labels,
                  filter: f,
                  search: false,
                  onChanged: (v) => setState(() => _filter = v),
                  onExport: () => _export(context, figures, sections, describe),
                ),
              ),
            const SizedBox(height: 4),
            Expanded(
              child: totals.all.flights == 0
                  ? Center(
                      child: Text(
                        all.isEmpty
                            ? 'No flights yet'
                            : 'No flights match the filter',
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, box) => box.maxWidth < 700
                          ? _Phone(figures, sections, box.maxWidth)
                          : _Wide(figures, sections),
                    ),
            ),
          ],
        );
      },
    );
  }

  static List<StatsFigure> _figures(FlightTotals totals) {
    final all = totals.all;
    return [
      StatsFigure('Flights', '${all.flights}'),
      StatsFigure('Flight time', formatDuration(all.seconds)),
      StatsFigure(
        'Aborted missions',
        '${all.aborted}',
        note: _share(all.aborted, all.flights),
        warn: all.aborted > 0,
      ),
      StatsFigure(
        'Near misses',
        '${all.nearMisses}',
        note: _share(all.nearMisses, all.flights),
        warn: all.nearMisses > 0,
      ),
      StatsFigure(
        'Flying days',
        '${totals.days}',
        note: totals.firstDate == null
            ? null
            : '${totals.firstDate} – ${totals.lastDate}',
      ),
      StatsFigure(
        'Flights per day',
        totals.days == 0 ? '–' : (all.flights / totals.days).toStringAsFixed(1),
      ),
      StatsFigure('Average flight', formatDuration(all.averageSeconds)),
      StatsFigure('Longest flight', formatDuration(totals.longestSeconds)),
    ];
  }

  Future<void> _export(
    BuildContext context,
    List<StatsFigure> figures,
    List<StatsSection> sections,
    String filters,
  ) async {
    try {
      final bytes = await statsPdf(
        title: 'Pilot Statistic',
        figures: figures,
        sections: sections,
        filters: filters,
        regular: await rootBundle.load('assets/fonts/Barlow-Regular.ttf'),
        bold: await rootBundle.load('assets/fonts/Barlow-SemiBold.ttf'),
      );
      if (!context.mounted) return;
      await deliverPdf(
        context,
        title: 'Pilot Statistic',
        bytes: bytes,
        what: 'the statistic',
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('PDF export failed: $e')));
      }
    }
  }

  static String? _share(int n, int of) => of == 0 || n == 0
      ? null
      : '${(100 * n / of).toStringAsFixed(1)}% of flights';

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

/// Phones: the figures two by two across the whole width, a month chart,
/// and every section as a card of bars instead of a wide table.
class _Phone extends StatelessWidget {
  const _Phone(this.figures, this.sections, this.width);
  final List<StatsFigure> figures;
  final List<StatsSection> sections;
  final double width;

  @override
  Widget build(BuildContext context) {
    const pad = 12.0;
    const gap = 10.0;
    final tile = (width - 2 * pad - gap) / 2;
    return ListView(
      padding: const EdgeInsets.fromLTRB(pad, 4, pad, 24),
      children: [
        Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final f in figures) _Tile(f, width: tile)],
        ),
        for (final s in sections)
          if (s.rows.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SectionCard(s),
          ],
      ],
    );
  }
}

/// Windows, Mac and tablets: the figures in a row, the sections as tables
/// side by side.
class _Wide extends StatelessWidget {
  const _Wide(this.figures, this.sections);
  final List<StatsFigure> figures;
  final List<StatsSection> sections;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [for (final f in figures) _Tile(f, width: 160)],
      ),
      const SizedBox(height: 24),
      Wrap(
        spacing: 24,
        runSpacing: 24,
        children: [
          for (final s in sections)
            if (s.rows.isNotEmpty) _StatTable(s),
        ],
      ),
    ],
  );
}

/// One big number.
class _Tile extends StatelessWidget {
  const _Tile(this.figure, {required this.width});
  final StatsFigure figure;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = theme.extension<CheckColors>()!.problem;
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(figure.label, style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  figure.value,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: figure.warn ? problem : null,
                  ),
                ),
              ),
              if (figure.note != null)
                Text(
                  figure.note!,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bar [of] the longest, [value] long.
class _Bar extends StatelessWidget {
  const _Bar(this.value, this.of, {this.height = 8});
  final int value;
  final int of;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: scheme.primary.withValues(alpha: 0.12)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: of == 0 ? 0 : value / of,
              child: ColoredBox(color: scheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section on a phone: name and flights, a bar, then time and safety
/// events in small print. Months also get a column chart.
class _SectionCard extends StatelessWidget {
  const _SectionCard(this.section);
  final StatsSection section;

  @override
  Widget build(BuildContext context) {
    final s = section;
    final theme = Theme.of(context);
    final problem = theme.extension<CheckColors>()!.problem;
    final small = theme.textTheme.bodySmall;
    final most = s.most;
    final sum = s.sum;
    final months = s.bars;
    Widget row(FlightStat r) {
      final details = <InlineSpan>[
        if (s.time) TextSpan(text: formatDuration(r.seconds)),
        if (s.safety && r.aborted > 0)
          TextSpan(
            text: '${s.time ? ' · ' : ''}${r.aborted} aborted',
            style: TextStyle(color: problem),
          ),
        if (s.safety && r.nearMisses > 0)
          TextSpan(
            text:
                '${s.time || r.aborted > 0 ? ' · ' : ''}'
                '${r.nearMisses} near miss',
            style: TextStyle(color: problem),
          ),
      ];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.name,
                    style: theme.textTheme.bodyLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${r.flights}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _Bar(r.flights, most),
            if (details.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text.rich(TextSpan(children: details), style: small),
            ],
          ],
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(s.title, style: theme.textTheme.titleMedium),
                ),
                Text(
                  s.time
                      ? '${sum.flights} · ${formatDuration(sum.seconds)}'
                      : '${sum.flights}',
                  style: small,
                ),
              ],
            ),
            if (months) ...[
              const SizedBox(height: 12),
              _MonthChart(s.rows),
              const SizedBox(height: 4),
            ],
            const SizedBox(height: 4),
            for (final r in s.rows) row(r),
          ],
        ),
      ),
    );
  }
}

/// Flights per month as columns, oldest on the left. [months] come newest
/// first, named yyyy-MM.
class _MonthChart extends StatelessWidget {
  const _MonthChart(this.months);
  final List<FlightStat> months;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = months.reversed.toList();
    final most = shown.fold(0, (n, m) => m.flights > n ? m.flights : n);
    final small = theme.textTheme.labelSmall;
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final m in shown)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FittedBox(child: Text('${m.flights}', style: small)),
                    const SizedBox(height: 2),
                    Flexible(
                      child: FractionallySizedBox(
                        heightFactor: most == 0 ? 0 : m.flights / most,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      child: Text(
                        m.name.length >= 7 ? m.name.substring(5, 7) : m.name,
                        style: small,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A section on a wide screen: flights, time, aborted missions and near
/// misses per group, with a total row when the section has one.
class _StatTable extends StatelessWidget {
  const _StatTable(this.section);
  final StatsSection section;

  @override
  Widget build(BuildContext context) {
    final s = section;
    final theme = Theme.of(context);
    final most = s.most;
    const bold = TextStyle(fontWeight: FontWeight.bold);
    List<DataCell> cells(FlightStat r, {TextStyle? style}) => [
      DataCell(Text(r.name, style: style)),
      DataCell(Text('${r.flights}', style: style)),
      if (s.bars)
        DataCell(
          SizedBox(
            width: 120,
            child: style != null ? null : _Bar(r.flights, most, height: 10),
          ),
        ),
      if (s.time) DataCell(Text(formatDuration(r.seconds), style: style)),
      if (s.safety) ...[
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
        Text(s.title, style: theme.textTheme.titleMedium),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 24,
            columns: [
              const DataColumn(label: Text('Name')),
              const DataColumn(label: Text('Flights'), numeric: true),
              if (s.bars) const DataColumn(label: Text('')),
              if (s.time) const DataColumn(label: Text('Time'), numeric: true),
              if (s.safety) ...const [
                DataColumn(label: Text('Aborted'), numeric: true),
                DataColumn(label: Text('Near miss'), numeric: true),
              ],
            ],
            rows: [
              for (final r in s.rows) DataRow(cells: cells(r)),
              if (s.total && s.rows.length > 1)
                DataRow(cells: cells(s.sum, style: bold)),
            ],
          ),
        ),
      ],
    );
  }
}
