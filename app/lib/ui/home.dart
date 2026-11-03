import 'package:flutter/material.dart';

import '../data/maintenance.dart';
import 'daily_checks_page.dart';
import 'documents_page.dart';
import 'faults_page.dart';
import 'flights_page.dart';
import 'maintenance_page.dart';
import 'nm_page.dart';
import 'reference_page.dart';
import 'services.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'theme.dart';

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
    (Icons.checklist, 'Daily checks'),
    (Icons.handyman, 'Fault Repair'),
    (Icons.engineering, 'Maintenance'),
    (Icons.bar_chart, 'Statistic'),
    (Icons.list_alt, 'Reference data'),
    (Icons.build, 'Nm'),
    (Icons.description, 'Documents'),
    (Icons.settings, 'Settings'),
  ];

  Widget _page() => switch (_index) {
    0 => const FlightsPage(kind: 'cargo', title: 'Cargo LogBook'),
    1 => const FlightsPage(kind: 'inspection', title: 'Inspection LogBook'),
    2 => const DailyChecksPage(),
    3 => const FaultsPage(),
    4 => const MaintenancePage(),
    5 => const StatsPage(),
    6 => const ReferencePage(),
    7 => const NmPage(),
    8 => const DocumentsPage(),
    _ => const SettingsPage(),
  };

  @override
  Widget build(BuildContext context) {
    // Phones get a drawer; wider windows keep the rail always visible.
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      appBar: AppBar(
        title: Text(narrow ? _pages[_index].$2 : 'Pilot Logbook'),
        actions: [
          _AlertCounts(onOpen: (i) => setState(() => _index = i)),
          const SyncButton(),
          const SizedBox(width: 8),
        ],
      ),
      drawer: narrow
          ? NavigationDrawer(
              selectedIndex: _index,
              onDestinationSelected: (i) {
                setState(() => _index = i);
                Navigator.pop(context);
              },
              children: [
                const SizedBox(height: 16),
                for (final (icon, label) in _pages)
                  NavigationDrawerDestination(
                    icon: Icon(icon),
                    label: Text(label),
                  ),
              ],
            )
          : null,
      body: narrow
          ? _page()
          : Row(
              children: [
                // Scrolls when the window is too low for every item.
                LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: NavigationRail(
                          selectedIndex: _index,
                          onDestinationSelected: (i) =>
                              setState(() => _index = i),
                          labelType: NavigationRailLabelType.all,
                          destinations: [
                            for (final (icon, label) in _pages)
                              NavigationRailDestination(
                                icon: Icon(icon),
                                label: Text(label),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _page()),
              ],
            ),
    );
  }
}

/// Counts at the top of the app that need someone: drones due for
/// maintenance. Tapping one opens its page ([onOpen] gets the page index).
class _AlertCounts extends StatelessWidget {
  const _AlertCounts({required this.onOpen});
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) => DbBuilder(
    builder: (context) {
      final services = Services.of(context);
      final drones = MaintenanceLog(services.db).dueCount();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (drones > 0)
            _AlertCount(
              key: const Key('alert-maintenance'),
              icon: Icons.engineering,
              count: drones,
              tooltip: drones == 1
                  ? '1 drone due for maintenance'
                  : '$drones drones due for maintenance',
              onTap: () => onOpen(4),
            ),
        ],
      );
    },
  );
}

class _AlertCount extends StatelessWidget {
  const _AlertCount({
    super.key,
    required this.icon,
    required this.count,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final int count;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: TextButton.icon(
      style: TextButton.styleFrom(foregroundColor: Colors.white),
      onPressed: onTap,
      icon: Icon(icon),
      label: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(
          color: AppPalette.gold,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '$count',
          style: const TextStyle(
            color: AppPalette.text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ),
  );
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
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              disabledForegroundColor: Colors.white70,
            ),
            onPressed: sync.running ? null : sync.sync,
            icon: sync.running
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    sync.lastError != null || !sync.configured
                        ? Icons.cloud_off
                        : Icons.sync,
                  ),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Sync'),
                if (pending > 0) ...[
                  const SizedBox(width: 6),
                  // Gold count of changes still waiting for upload.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.gold,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$pending',
                      style: const TextStyle(
                        color: AppPalette.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
