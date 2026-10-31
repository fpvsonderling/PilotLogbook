import 'package:flutter/material.dart';

import '../data/logbook.dart';
import '../data/schema.dart';
import 'fault_screen.dart';
import 'fault_widgets.dart';
import 'services.dart';

/// Fault Repair Report: open faults first (grounded on top), then the ones
/// waiting for a test, then the closed ones.
class FaultsPage extends StatefulWidget {
  const FaultsPage({super.key});

  @override
  State<FaultsPage> createState() => _FaultsPageState();
}

class _FaultsPageState extends State<FaultsPage> {
  /// null shows every fault.
  FaultStatus? _status = FaultStatus.open;

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showFaultForm(context, const FaultReportForm()),
        icon: const Icon(Icons.report_problem_outlined),
        label: const Text('Report fault'),
      ),
      body: DbBuilder(
        builder: (context) {
          final all = logbook.faultCases();
          final aircraft = logbook.names(Tables.aircraft);
          final batteries = logbook.names(Tables.batteries);
          final people = logbook.names(Tables.people);
          final theme = Theme.of(context);
          final count = {
            for (final s in FaultStatus.values)
              s: all.where((c) => c.status == s).length,
          };
          final grounded = {
            for (final c in all)
              if (c.grounded) faultSubject(c, aircraft, batteries),
          };
          final shown = _status == null
              ? all
              : all.where((c) => c.status == _status).toList();
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  Text(
                    'Fault Repair Report',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  if (grounded.isNotEmpty) ...[
                    _GroundedBanner(grounded.toList()),
                    const SizedBox(height: 12),
                  ],
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<FaultStatus?>(
                      showSelectedIcon: false,
                      segments: [
                        for (final s in FaultStatus.values)
                          ButtonSegment(
                            value: s,
                            label: Text(
                              '${switch (s) {
                                FaultStatus.open => 'Not fixed',
                                FaultStatus.repaired => 'Waiting for test',
                                FaultStatus.closed => 'Fixed and tested',
                              }} (${count[s]})',
                            ),
                          ),
                        ButtonSegment(
                          value: null,
                          label: Text('All (${all.length})'),
                        ),
                      ],
                      selected: {_status},
                      onSelectionChanged: (s) =>
                          setState(() => _status = s.first),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (shown.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Center(
                        child: Text(
                          all.isEmpty ? 'No faults reported' : 'Nothing here',
                        ),
                      ),
                    ),
                  for (final c in shown)
                    _FaultCard(
                      fault: c,
                      subject: faultSubject(c, aircraft, batteries),
                      people: people,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GroundedBanner extends StatelessWidget {
  const _GroundedBanner(this.subjects);
  final List<String> subjects;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.block, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'GROUNDED: ${subjects.join(', ')}',
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FaultCard extends StatelessWidget {
  const _FaultCard({
    required this.fault,
    required this.subject,
    required this.people,
  });

  final FaultCase fault;
  final String subject;
  final Map<String, String> people;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = fault;
    final photo = c.photos.firstOrNull;
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final last = c.repairs.lastOrNull;
    final passed = c.passedSignoff;
    final footer = switch (c.status) {
      FaultStatus.open => [
        'Reported ${c.reportedAt}',
        if (personName(people, c.fault['discovered_by_id']) case final n
            when n.isNotEmpty)
          'by $n',
        if (_daysSince(c.reportedAt) case final d? when d > 0)
          '· $d ${d == 1 ? 'day' : 'days'} open',
      ],
      FaultStatus.repaired => [
        'Repaired ${FaultCase.repairTime(last!)}',
        if ((last['technicians'] as String? ?? '').isNotEmpty)
          'by ${last['technicians']}',
        '· waiting for test',
      ],
      FaultStatus.closed => [
        'Closed ${passed!['tested_at'] ?? ''}',
        if (personName(people, passed['signatory_id']) case final n
            when n.isNotEmpty)
          '· signed by $n',
      ],
    }.join(' ');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openFault(context, c.id),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: photo == null
                    ? SizedBox.square(
                        dimension: 72,
                        child: ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.build_outlined,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : FaultPhoto(photo),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(subject, style: theme.textTheme.titleMedium),
                        Pill(
                          c.grounded
                              ? 'GROUNDED'
                              : 'Class ${c.severity == 0 ? '?' : c.severity}',
                          severityColors(context, c.severity),
                          icon: c.grounded ? Icons.block : null,
                        ),
                        Pill(
                          statusTitles[c.status]!,
                          statusColors(context, c.status),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      c.fault['description'] as String? ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(footer, style: muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static int? _daysSince(String at) {
    final t = DateTime.tryParse(at);
    return t == null ? null : DateTime.now().difference(t).inDays;
  }
}
