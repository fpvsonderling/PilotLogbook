import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import 'flight_form.dart';
import 'services.dart';

/// Flights of one kind, newest first, grouped by day like the old AppSheet.
class FlightsPage extends StatelessWidget {
  const FlightsPage({super.key, required this.kind, required this.title});

  final String kind;
  final String title;

  static const _columns = [
    ('Date', 90.0),
    ('Project', 130.0),
    ('Drone', 70.0),
    ('Take off', 80.0),
    ('Land', 80.0),
    ('Time', 70.0),
    ('Batt', 50.0),
    ('Used', 50.0),
    ('Temp', 50.0),
    ('What', 140.0),
    ('RP', 140.0),
    ('PA', 140.0),
    ('Spotter', 140.0),
    ('Notes', 260.0),
  ];

  static final double _width = _columns.fold(32.0, (w, c) => w + c.$2);

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showFlightForm(context, kind: kind),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: DbBuilder(
        builder: (context) {
          final flights = logbook.flights(kind: kind);
          final projects = logbook.names(Tables.projects);
          final aircraft = logbook.names(Tables.aircraft);
          final batteries = logbook.names(Tables.batteries);
          final people = logbook.names(Tables.people);
          final services = Services.of(context);
          final days = <String, List<DbRow>>{};
          for (final f in flights) {
            days.putIfAbsent(f['date'] as String? ?? '', () => []).add(f);
          }
          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '$title · ${flights.length} flights',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: flights.isEmpty
                    ? const Center(child: Text('No flights yet'))
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
                          width: _width,
                          child: ListView(
                            padding: const EdgeInsets.only(bottom: 80),
                            children: [
                              _row([
                                for (final c in _columns) c.$1,
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
                                    child: _row([
                                      f['date'] as String? ?? '',
                                      projects[f['project_id']] ?? '',
                                      aircraft[f['aircraft_id']] ?? '',
                                      f['takeoff_at'] as String? ?? '',
                                      f['landing_at'] as String? ?? '',
                                      formatDuration(f['duration_s'] as int?),
                                      batteries[f['battery_id']] ?? '',
                                      '${f['used'] ?? ''}',
                                      '${f['temp_c'] ?? ''}',
                                      f['mission'] as String? ?? '',
                                      people[f['rp_id']] ?? '',
                                      people[f['pa_id']] ?? '',
                                      people[f['spotter_id']] ?? '',
                                      f['notes'] as String? ?? '',
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

  Widget _row(List<String> cells, {TextStyle? style}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        for (var i = 0; i < cells.length; i++)
          SizedBox(
            width: _columns[i].$2,
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
