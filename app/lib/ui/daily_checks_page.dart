import 'package:flutter/material.dart';

import '../data/schema.dart';
import 'daily_check_screen.dart';
import 'services.dart';
import 'theme.dart';

/// Saved daily checks, newest first, with their problems.
class DailyChecksPage extends StatelessWidget {
  const DailyChecksPage({super.key});

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
          final checks = logbook.dailyChecks();
          final aircraft = logbook.names(Tables.aircraft);
          final people = logbook.names(Tables.people);
          final services = Services.of(context);
          final theme = Theme.of(context);
          final colors = CheckColors.of(context);
          if (checks.isEmpty) {
            return const Center(child: Text('No daily checks yet'));
          }
          // Full window width: on a wide screen a check is one line, drone
          // and date on the left, its problems next to them.
          return LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 900;
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: checks.length + 1,
                separatorBuilder: (_, _) => SizedBox(height: wide ? 6 : 10),
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Text(
                      'Daily checks · ${checks.length}',
                      style: theme.textTheme.titleLarge,
                    );
                  }
                  final c = checks[i - 1];
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
                      if ((people[c.row['pilot_id']] ?? '').isNotEmpty)
                        people[c.row['pilot_id']],
                    ].join(' · '),
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
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
                        padding: EdgeInsets.only(top: wide ? 0 : 6, bottom: 2),
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
          );
        },
      ),
    );
  }
}
