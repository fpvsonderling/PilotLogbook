import 'package:flutter/material.dart';

import '../data/maintenance.dart';
import '../data/schema.dart';
import '../data/table_filter.dart';
import 'maintenance_screen.dart';
import 'due_colors.dart';
import 'services.dart';
import 'table_tools.dart';
import 'theme.dart';

/// Each drone's flying since its last maintenance, then every saved
/// maintenance, newest first.
class MaintenancePage extends StatefulWidget {
  const MaintenancePage({super.key});

  @override
  State<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends State<MaintenancePage> {
  var _filter = const TableFilter();

  static final _fields = <FilterField<Maintenance>>[
    FilterField('drone', 'Drone', (m) => [m.aircraftId]),
    FilterField(
      'technician',
      'Technician',
      (m) => [m.row['technician_id'] as String?],
    ),
  ];

  static List<TableColumn<Maintenance>> _columns(
    Map<String, String> aircraft,
    Map<String, String> people,
  ) => [
    TableColumn('Date', 95, (m) => m.performedAt),
    TableColumn('Drone', 45, (m) => aircraft[m.aircraftId] ?? ''),
    TableColumn('Technician', 100, (m) => people[m.row['technician_id']] ?? ''),
    for (final s in maintenanceSections)
      TableColumn(s.title, s.column == 'fts' ? 50 : 90, (m) => m.value(s)),
    TableColumn('Notes', 120, (m) => m.row['notes'] as String? ?? ''),
  ];

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    return Scaffold(
      floatingActionButton: AddButton(
        child: FloatingActionButton.extended(
          onPressed: () => openMaintenance(context),
          icon: const Icon(Icons.engineering),
          label: const Text('New maintenance'),
        ),
      ),
      body: DbBuilder(
        builder: (context) {
          final log = MaintenanceLog(services.db);
          final logbook = services.logbook;
          final all = log.all();
          final drones = log.drones();
          final aircraft = logbook.names(Tables.aircraft);
          final people = logbook.names(Tables.people);
          final theme = Theme.of(context);
          final columns = _columns(aircraft, people);
          final labels = {'drone': aircraft, 'technician': people};
          final rows = _filter.apply(
            all,
            date: (m) => m.performedAt,
            fields: _fields,
            columns: columns,
          );
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Since last maintenance',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: drones.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text('Add drones under Reference data'),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: LayoutBuilder(
                          builder: (context, box) {
                            // At least two tiles per row, at most 180 wide.
                            const gap = 8.0;
                            final width = ((box.maxWidth - gap) / 2)
                                .clamp(0.0, 180.0)
                                .toDouble();
                            return Wrap(
                              spacing: gap,
                              runSpacing: gap,
                              children: [
                                for (final d in drones)
                                  _DroneCard(drone: d, width: width),
                              ],
                            );
                          },
                        ),
                      ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    _filter.isEmpty
                        ? 'Maintenance · ${rows.length}'
                        : 'Maintenance · ${rows.length} of ${all.length}',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
              ),
              if (all.isNotEmpty)
                SliverToBoxAdapter(
                  child: FilterBar<Maintenance>(
                    rows: all,
                    fields: _fields,
                    labels: labels,
                    filter: _filter,
                    onChanged: (f) => setState(() => _filter = f),
                    onExport: () => exportTablePdf(
                      context,
                      title: 'Maintenance',
                      columns: columns,
                      rows: rows,
                      filters: _filter.describe(
                        _fields,
                        (key, v) => labels[key]?[v] ?? v,
                      ),
                      summary: ['${rows.length} maintenance records'],
                    ),
                  ),
                ),
              if (rows.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        all.isEmpty
                            ? 'No maintenance yet'
                            : 'Nothing matches the filter',
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  sliver: SliverList.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _MaintenanceCard(
                      maintenance: rows[i],
                      drone: aircraft[rows[i].aircraftId] ?? '?',
                      technician: people[rows[i].row['technician_id']] ?? '',
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

Urgency urgencyOf(DueLevel l) => switch (l) {
  DueLevel.ok => Urgency.ok,
  DueLevel.soon => Urgency.soon,
  DueLevel.overdue => Urgency.over,
};

class _DroneCard extends StatelessWidget {
  const _DroneCard({required this.drone, required this.width});
  final DroneMaintenance drone;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = drone.last;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final urgency = urgencyOf(drone.level);
    final (fg, bg) = urgencyColors(context, urgency);
    final due = drone.due;
    return SizedBox(
      width: width,
      child: Card(
        key: Key('drone-card-${drone.name}'),
        color: bg,
        shape: fg == null
            ? null
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: fg, width: 1.5),
              ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _showDue(context, drone),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Drone ${drone.name}',
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  last == null
                      ? 'No maintenance yet'
                      : 'Last ${_day(last.performedAt)}',
                  style: muted,
                ),
                const SizedBox(height: 4),
                Text(
                  '${formatHours(drone.secondsSince)} h',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${drone.flightsSince} '
                  '${drone.flightsSince == 1 ? 'flight' : 'flights'}'
                  '${last == null ? ' in total' : ' since'}',
                  style: muted,
                ),
                if (due.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    due.first.level == DueLevel.overdue
                        ? 'Due: ${due.map((d) => d.section.title).join(', ')}'
                        : 'Soon: ${due.map((d) => d.section.title).join(', ')}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Each assembly of a drone against its interval, and a button to start
/// the maintenance.
Future<void> _showDue(BuildContext context, DroneMaintenance drone) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final canAdd = Services.of(context).canAdd;
        return AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text('Drone ${drone.name}'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in drone.sections)
                  Padding(
                    key: Key('due-${s.section.column}'),
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.section.title,
                                style: theme.textTheme.titleSmall,
                              ),
                              Text(
                                [
                                  s.lastAt == null
                                      ? 'Never done'
                                      : 'Last ${_day(s.lastAt!)}',
                                  'every ${s.interval.describe()}',
                                ].join(' · '),
                                style: theme.textTheme.bodySmall,
                              ),
                              if (!s.interval.isOff)
                                Text(
                                  s.describe(),
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        UrgencyPill(switch (s.level) {
                          DueLevel.ok => s.interval.isOff ? 'Off' : 'OK',
                          DueLevel.soon => 'Soon',
                          DueLevel.overdue => 'Due',
                        }, urgencyOf(s.level)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            if (canAdd)
              FilledButton.icon(
                key: const Key('start-maintenance'),
                onPressed: () {
                  Navigator.pop(dialogContext);
                  openMaintenance(context, aircraftId: drone.aircraftId);
                },
                icon: const Icon(Icons.engineering),
                label: const Text('New maintenance'),
              ),
          ],
        );
      },
    );

/// "2026-08-07 10:48:45" -> "07.08.2026"
String _day(String at) {
  final p = at.split(' ').first.split('-');
  return p.length == 3 ? '${p[2]}.${p[1]}.${p[0]}' : at;
}

/// Flight time as hours and minutes: 45000 s -> "12:30".
String formatHours(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return '$h:${m.toString().padLeft(2, '0')}';
}

class _MaintenanceCard extends StatelessWidget {
  const _MaintenanceCard({
    required this.maintenance,
    required this.drone,
    required this.technician,
  });

  final Maintenance maintenance;
  final String drone;
  final String technician;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = CheckColors.of(context);
    final services = Services.of(context);
    final m = maintenance;
    final done = m.done.length;
    final total = maintenanceSections.length;
    final notes = m.row['notes'] as String? ?? '';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: services.canChange(m.row)
            ? () => openMaintenance(context, maintenance: m)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Drone $drone',
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(
                          [
                            _day(m.performedAt),
                            if (technician.isNotEmpty) technician,
                          ].join(' · '),
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.okContainer,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(
                      '$done / $total checked',
                      style: TextStyle(
                        color: colors.ok,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              for (final (s, text) in m.work)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${s.title}: ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(text: text),
                      ],
                    ),
                  ),
                ),
              if (notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    notes,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
