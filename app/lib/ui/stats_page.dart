import 'package:flutter/material.dart';

import '../data/logbook.dart';
import 'services.dart';

/// Counted from the flights themselves, so it is never out of date.
class StatsPage extends StatelessWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    return DbBuilder(
      builder: (context) {
        final pilots = logbook.pilotStats();
        final spotters = logbook.spotterStats();
        final totalFlights = pilots.fold(0, (n, p) => n + p.flights);
        final totalSeconds = pilots.fold(0, (n, p) => n + p.seconds);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Pilots (as RP)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            DataTable(
              columns: const [
                DataColumn(label: Text('Name')),
                DataColumn(label: Text('Flights'), numeric: true),
                DataColumn(label: Text('Time'), numeric: true),
              ],
              rows: [
                for (final p in pilots)
                  DataRow(
                    cells: [
                      DataCell(Text(p.name)),
                      DataCell(Text('${p.flights}')),
                      DataCell(Text(formatDuration(p.seconds))),
                    ],
                  ),
                DataRow(
                  cells: [
                    const DataCell(
                      Text(
                        'Total',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    DataCell(Text('$totalFlights')),
                    DataCell(Text(formatDuration(totalSeconds))),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Spotters', style: Theme.of(context).textTheme.titleMedium),
            DataTable(
              columns: const [
                DataColumn(label: Text('Name')),
                DataColumn(label: Text('Flights'), numeric: true),
              ],
              rows: [
                for (final s in spotters)
                  DataRow(
                    cells: [
                      DataCell(Text(s.name)),
                      DataCell(Text('${s.flights}')),
                    ],
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
