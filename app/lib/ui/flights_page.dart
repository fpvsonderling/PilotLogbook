import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import '../data/table_filter.dart';
import 'flight_form.dart';
import 'services.dart';
import 'table_tools.dart';

/// Flights of one kind, newest first, grouped by day like the old AppSheet,
/// with filters and a PDF of what the filters show.
class FlightsPage extends StatefulWidget {
  const FlightsPage({super.key, required this.kind, required this.title});

  final String kind;
  final String title;

  @override
  State<FlightsPage> createState() => _FlightsPageState();
}

class _FlightsPageState extends State<FlightsPage> {
  var _filter = const TableFilter();

  static final _fields = <FilterField<DbRow>>[
    FilterField('project', 'Project', (f) => [f['project_id'] as String?]),
    FilterField('drone', 'Drone', (f) => [f['aircraft_id'] as String?]),
    // Anyone in the crew, so a person finds every flight they were on.
    FilterField(
      'pilot',
      'Pilot',
      (f) => [
        f['rp_id'] as String?,
        f['pa_id'] as String?,
        f['spotter_id'] as String?,
      ],
    ),
    FilterField('mission', 'What', (f) => [f['mission'] as String?]),
  ];

  static List<TableColumn<DbRow>> _columns({
    required Map<String, String> projects,
    required Map<String, String> aircraft,
    required Map<String, String> batteries,
    required Map<String, String> people,
  }) => [
    TableColumn('Date', 90, (f) => f['date'] as String? ?? ''),
    TableColumn('Project', 130, (f) => projects[f['project_id']] ?? ''),
    TableColumn('Drone', 70, (f) => aircraft[f['aircraft_id']] ?? ''),
    TableColumn('Take off', 80, (f) => f['takeoff_at'] as String? ?? ''),
    TableColumn('Land', 80, (f) => f['landing_at'] as String? ?? ''),
    TableColumn('Time', 70, (f) => formatDuration(f['duration_s'] as int?)),
    TableColumn('Batt', 50, (f) => batteries[f['battery_id']] ?? ''),
    TableColumn('Used', 50, (f) => '${f['used'] ?? ''}'),
    TableColumn('Temp', 50, (f) => '${f['temp_c'] ?? ''}'),
    TableColumn('What', 140, (f) => f['mission'] as String? ?? ''),
    TableColumn('RP', 140, (f) => people[f['rp_id']] ?? ''),
    TableColumn('PA', 140, (f) => people[f['pa_id']] ?? ''),
    TableColumn('Spotter', 140, (f) => people[f['spotter_id']] ?? ''),
    TableColumn('Notes', 260, (f) => f['notes'] as String? ?? ''),
  ];

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    final kind = widget.kind;
    final title = widget.title;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showFlightForm(context, kind: kind),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: DbBuilder(
        builder: (context) {
          final all = logbook.flights(kind: kind);
          final projects = logbook.names(Tables.projects);
          final aircraft = logbook.names(Tables.aircraft);
          final batteries = logbook.names(Tables.batteries);
          final people = logbook.names(Tables.people);
          final columns = _columns(
            projects: projects,
            aircraft: aircraft,
            batteries: batteries,
            people: people,
          );
          final labels = {
            'project': projects,
            'drone': aircraft,
            'pilot': people,
          };
          final flights = _filter.apply(
            all,
            date: (f) => f['date'] as String? ?? '',
            fields: _fields,
            columns: columns,
          );
          final width = columns.fold(32.0, (w, c) => w + c.width);
          final services = Services.of(context);
          final days = <String, List<DbRow>>{};
          for (final f in flights) {
            days.putIfAbsent(f['date'] as String? ?? '', () => []).add(f);
          }
          final seconds = flights.fold(
            0,
            (n, f) => n + ((f['duration_s'] as int?) ?? 0),
          );
          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  _filter.isEmpty
                      ? '$title · ${flights.length} flights'
                      : '$title · ${flights.length} of ${all.length} flights'
                            ' · ${formatDuration(seconds)}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (all.isNotEmpty)
                FilterBar<DbRow>(
                  rows: all,
                  fields: _fields,
                  labels: labels,
                  filter: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                  onExport: () => exportTablePdf(
                    context,
                    title: title,
                    columns: columns,
                    rows: flights,
                    filters: _filter.describe(
                      _fields,
                      (key, v) => labels[key]?[v] ?? v,
                    ),
                    summary: [
                      '${flights.length} flights',
                      'Flight time ${formatDuration(seconds)}',
                      '${{for (final f in flights) f['date']}.length} days',
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: all.isEmpty
                    ? const Center(child: Text('No flights yet'))
                    : flights.isEmpty
                    ? const Center(child: Text('No flights match the filter'))
                    : MediaQuery.sizeOf(context).width < 700
                    // Phones: one card per flight instead of the wide table.
                    ? ListView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 88),
                        children: [
                          for (final day in days.entries) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
                              child: Text(
                                '${day.key}  (${day.value.length})',
                                style: theme.textTheme.labelLarge,
                              ),
                            ),
                            for (final f in day.value)
                              _FlightCard(
                                flight: f,
                                project: projects[f['project_id']],
                                drone: aircraft[f['aircraft_id']],
                                battery: batteries[f['battery_id']],
                                rp: people[f['rp_id']],
                                onTap: services.canChange(f)
                                    ? () => showFlightForm(
                                        context,
                                        kind: kind,
                                        flight: f,
                                      )
                                    : null,
                              ),
                          ],
                        ],
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: width,
                          child: ListView(
                            padding: const EdgeInsets.only(bottom: 80),
                            children: [
                              _row(columns, [
                                for (final c in columns) c.header,
                              ], style: theme.textTheme.labelLarge),
                              const Divider(height: 1),
                              for (final day in days.entries) ...[
                                Container(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    '${day.key}  (${day.value.length})',
                                    style: theme.textTheme.labelLarge,
                                  ),
                                ),
                                for (final f in day.value)
                                  InkWell(
                                    onTap: services.canChange(f)
                                        ? () => showFlightForm(
                                            context,
                                            kind: kind,
                                            flight: f,
                                          )
                                        : null,
                                    child: _row(columns, [
                                      for (final c in columns) c.cell(f),
                                    ]),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(
    List<TableColumn<DbRow>> columns,
    List<String> cells, {
    TextStyle? style,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          SizedBox(
            width: columns[i].width,
            child: Text(
              cells[i],
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ),
  );
}

class _FlightCard extends StatelessWidget {
  const _FlightCard({
    required this.flight,
    required this.project,
    required this.drone,
    required this.battery,
    required this.rp,
    required this.onTap,
  });

  final DbRow flight;
  final String? project;
  final String? drone;
  final String? battery;
  final String? rp;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = flight;
    final times = [
      f['takeoff_at'] as String? ?? '',
      f['landing_at'] as String? ?? '',
    ].where((t) => t.isNotEmpty).join(' – ');
    final details = [
      if (rp != null) 'RP $rp',
      if (battery != null) 'Batt $battery',
      if (f['used'] != null) 'Used ${f['used']}',
      if (f['temp_c'] != null) '${f['temp_c']} °C',
    ].join(' · ');
    final notes = f['notes'] as String? ?? '';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      [if (drone != null) 'Drone $drone', ?project].join(' · '),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    formatDuration(f['duration_s'] as int?),
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              if (times.isNotEmpty || (f['mission'] as String? ?? '') != '')
                Text(
                  [
                    times,
                    f['mission'] as String? ?? '',
                  ].where((t) => t.isNotEmpty).join(' · '),
                ),
              if (details.isNotEmpty)
                Text(
                  details,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              if (notes.isNotEmpty)
                Text(
                  notes,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
