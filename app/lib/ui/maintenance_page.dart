import 'package:flutter/material.dart';

import '../data/maintenance.dart';
import '../data/schema.dart';
import '../data/table_filter.dart';
import 'maintenance_screen.dart';
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
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            for (final d in drones) _DroneCard(drone: d),
                          ],
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

class _DroneCard extends StatelessWidget {
  const _DroneCard({required this.drone});
  final DroneMaintenance drone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = drone.last;
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return SizedBox(
      width: 220,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openMaintenance(context, aircraftId: drone.aircraftId),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Drone ${drone.name}', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  last == null
                      ? 'No maintenance yet'
                      : 'Last ${_day(last.performedAt)}',
                  style: muted,
                ),
                const SizedBox(height: 8),
                Text(
                  '${formatHours(drone.secondsSince)} h',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${drone.flightsSince} '
                  '${drone.flightsSince == 1 ? 'flight' : 'flights'}'
                  '${last == null ? ' in total' : ' since'}',
                  style: muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
