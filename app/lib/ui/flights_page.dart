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
