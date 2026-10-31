import 'package:flutter/material.dart';

import '../data/logbook.dart';
import '../data/schema.dart';
import '../data/table_filter.dart';
import 'daily_check_screen.dart';
import 'services.dart';
import 'table_tools.dart';
import 'theme.dart';

/// Saved daily checks, newest first, with their problems.
class DailyChecksPage extends StatefulWidget {
  const DailyChecksPage({super.key});

  @override
  State<DailyChecksPage> createState() => _DailyChecksPageState();
}

class _DailyChecksPageState extends State<DailyChecksPage> {
  var _filter = const TableFilter();

  static const _ok = 'OK';
  static const _problems = 'Problems';

  static final _fields = <FilterField<DailyCheck>>[
    FilterField('drone', 'Drone', (c) => [c.row['aircraft_id'] as String?]),
    FilterField('pilot', 'Pilot', (c) => [c.row['pilot_id'] as String?]),
    FilterField('checklist', 'Checklist', (c) => [c.checklist.name]),
    FilterField(
      'result',
      'Result',
      (c) => [c.problems.isEmpty ? _ok : _problems],
    ),
  ];

  static List<TableColumn<DailyCheck>> _columns(
    Map<String, String> aircraft,
    Map<String, String> people,
  ) => [
    TableColumn('Checked', 95, (c) => c.checkedAt),
    TableColumn('Drone', 45, (c) => aircraft[c.row['aircraft_id']] ?? ''),
    TableColumn('Checklist', 110, (c) => c.checklist.name),
    TableColumn('Pilot', 100, (c) => people[c.row['pilot_id']] ?? ''),
    TableColumn(
      'Result',
      55,
      (c) => c.problems.isEmpty ? _ok : '${c.problems.length} problems',
    ),
    TableColumn(
      'Problems',
      300,
      (c) =>
          [for (final (s, note) in c.problems) '${s.title}: $note'].join('\n'),
    ),
    TableColumn('Notes', 140, (c) => c.row['notes'] as String? ?? ''),
  ];

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openDailyCheck(context),
        icon: const Icon(Icons.checklist),
        label: const Text('New daily check'),
      ),
      body: DbBuilder(
        builder: (context) {
          final all = logbook.dailyChecks();
          final aircraft = logbook.names(Tables.aircraft);
          final people = logbook.names(Tables.people);
          final services = Services.of(context);
          final theme = Theme.of(context);
          final colors = CheckColors.of(context);
          if (all.isEmpty) {
            return const Center(child: Text('No daily checks yet'));
          }
          final columns = _columns(aircraft, people);
          final labels = {'drone': aircraft, 'pilot': people};
          final checks = _filter.apply(
            all,
            date: (c) => c.checkedAt,
            fields: _fields,
            columns: columns,
          );
          final withProblems = checks.where((c) => c.problems.isNotEmpty);
          // Full window width: on a wide screen a check is one line, drone
          // and date on the left, its problems next to them.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  _filter.isEmpty
                      ? 'Daily checks · ${checks.length}'
                      : 'Daily checks · ${checks.length} of ${all.length}',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              FilterBar<DailyCheck>(
                rows: all,
                fields: _fields,
                labels: labels,
                filter: _filter,
                onChanged: (f) => setState(() => _filter = f),
                onExport: () => exportTablePdf(
                  context,
                  title: 'Daily checks',
                  columns: columns,
                  rows: checks,
                  filters: _filter.describe(
                    _fields,
                    (key, v) => labels[key]?[v] ?? v,
                  ),
                  summary: [
                    '${checks.length} checks',
                    '${withProblems.length} with problems',
                  ],
                ),
              ),
              Expanded(
                child: checks.isEmpty
                    ? const Center(child: Text('No checks match the filter'))
                    : LayoutBuilder(
                        builder: (context, box) {
                          final wide = box.maxWidth >= 900;
                          return ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                            itemCount: checks.length,
                            separatorBuilder: (_, _) =>
                                SizedBox(height: wide ? 6 : 10),
                            itemBuilder: (context, i) {
                              final c = checks[i];
                              final problems = c.problems;
                              final good = problems.isEmpty;
                              final title = Text(
                                'Drone ${aircraft[c.row['aircraft_id']] ?? '?'}'
                                ' · ${c.checklist.name}',
                                style: theme.textTheme.titleMedium,
                              );
                              final when = Text(
                                [
                                  c.checkedAt,
                                  if ((people[c.row['pilot_id']] ?? '')
                                      .isNotEmpty)
                                    people[c.row['pilot_id']],
                                ].join(' · '),
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              );
                              final badge = Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: good
                                      ? colors.okContainer
                                      : colors.problemContainer,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Text(
                                  good
                                      ? 'OK'
                                      : '${problems.length} '
                                            '${problems.length == 1 ? 'problem' : 'problems'}',
                                  style: TextStyle(
                                    color: good ? colors.ok : colors.problem,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                              final problemLines = [
                                for (final (s, note) in problems)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      top: wide ? 0 : 6,
                                      bottom: 2,
                                    ),
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: '${s.title}: ',
                                            style: TextStyle(
                                              color: colors.problem,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          TextSpan(text: note),
                                        ],
                                      ),
                                    ),
                                  ),
                              ];
                              return Card(
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: services.canChange(c.row)
                                      ? () => openDailyCheck(context, check: c)
                                      : null,
                                  child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: wide
                                        ? Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              SizedBox(
                                                width: 300,
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    title,
                                                    const SizedBox(height: 2),
                                                    when,
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 16),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: problemLines,
                                                ),
                                              ),
                                              const SizedBox(width: 16),
                                              badge,
                                            ],
                                          )
                                        : Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(child: title),
                                                  badge,
                                                ],
                                              ),
                                              const SizedBox(height: 2),
                                              when,
                                              ...problemLines,
                                            ],
                                          ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
