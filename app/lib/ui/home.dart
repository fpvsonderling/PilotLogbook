import 'package:flutter/material.dart';

import 'flights_page.dart';
import 'reference_page.dart';
import 'services.dart';
import 'settings_page.dart';
import 'stats_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static const _pages = [
    (Icons.flight_takeoff, 'Cargo LogBook'),
    (Icons.search, 'Inspection LogBook'),
    (Icons.favorite, 'Pilot Statistic'),
    (Icons.list_alt, 'Reference data'),
    (Icons.settings, 'Settings'),
  ];

  Widget _page() => switch (_index) {
    0 => const FlightsPage(kind: 'cargo', title: 'Cargo LogBook'),
    1 => const FlightsPage(kind: 'inspection', title: 'Inspection LogBook'),
    2 => const StatsPage(),
    3 => const ReferencePage(),
    _ => const SettingsPage(),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pilot Logbook'),
        actions: const [SyncButton(), SizedBox(width: 8)],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final (icon, label) in _pages)
                NavigationRailDestination(icon: Icon(icon), label: Text(label)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _page()),
        ],
      ),
    );
  }
}

/// Shows sync state and how many local changes wait for upload.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final sync = services.sync;
    return ListenableBuilder(
      listenable: Listenable.merge([sync, services.db.changes]),
      builder: (context, _) {
        final pending = sync.pendingCount;
        final String tip;
        if (!sync.configured) {
          tip = 'Sync is not set up: open Settings';
        } else if (sync.lastError != null) {
          tip = 'Last sync failed: ${sync.lastError}';
        } else if (pending > 0) {
          tip = '$pending changes wait for upload';
        } else {
          tip = 'Up to date';
        }
        return Tooltip(
          message: tip,
          child: TextButton.icon(
            onPressed: sync.running ? null : sync.sync,
            icon: sync.running
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    sync.lastError != null || !sync.configured
                        ? Icons.cloud_off
                        : Icons.sync,
                  ),
            label: Text(pending > 0 ? 'Sync ($pending)' : 'Sync'),
          ),
        );
      },
    );
  }
}
