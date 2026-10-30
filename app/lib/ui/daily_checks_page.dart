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
          final admin = Services.of(context).isAdmin;
          final theme = Theme.of(context);
          final colors = CheckColors.of(context);
          if (checks.isEmpty) {
            return const Center(child: Text('No daily checks yet'));
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: checks.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                  return Card(
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: admin
                          ? () => openDailyCheck(context, check: c)
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Drone ${aircraft[c.row['aircraft_id']] ?? '?'}'
                                    ' · ${c.checklist.name}',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                Container(
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
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${c.checkedAt} · '
                              '${people[c.row['pilot_id']] ?? ''}',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            for (final (s, note) in problems)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
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
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
