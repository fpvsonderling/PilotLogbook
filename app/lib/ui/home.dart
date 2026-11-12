import 'package:flutter/material.dart';

import '../data/maintenance.dart';
import '../data/competencies.dart';
import 'competencies_page.dart';
import 'daily_checks_page.dart';
import 'documents_page.dart';
import 'faults_page.dart';
import 'flights_page.dart';
import 'maintenance_page.dart';
import 'nm_page.dart';
import 'notifications_ui.dart';
import 'projects_page.dart';
import 'reference_page.dart';
import 'services.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'theme.dart';
import 'update_banner.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;

  static final _pages = <(IconData, String, Widget Function())>[
    (
      Icons.flight_takeoff,
      'Cargo LogBook',
      () => const FlightsPage(kind: 'cargo', title: 'Cargo LogBook'),
    ),
    (
      Icons.search,
      'Inspection LogBook',
      () => const FlightsPage(kind: 'inspection', title: 'Inspection LogBook'),
    ),
    (Icons.checklist, 'Daily checks', () => const DailyChecksPage()),
    (Icons.handyman, 'Fault Repair', () => const FaultsPage()),
    (Icons.engineering, 'Maintenance', () => const MaintenancePage()),
    (Icons.location_on, 'Projects', () => const ProjectsPage()),
    (Icons.verified_user, 'Competencies', () => const CompetenciesPage()),
    (Icons.bar_chart, 'Statistic', () => const StatsPage()),
    (Icons.list_alt, 'Reference data', () => const ReferencePage()),
    (Icons.build, 'Nm', () => const NmPage()),
    (Icons.description, 'Documents', () => const DocumentsPage()),
    (Icons.settings, 'Settings', () => const SettingsPage()),
  ];

  /// Index of the page called [label].
  static int pageIndex(String label) => _pages.indexWhere((p) => p.$2 == label);

  Widget _page() => _pages[_index].$3();

  ValueNotifier<String?>? _openPage;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final open = Services.of(context).push?.openPage;
    if (open != _openPage) {
      _openPage?.removeListener(_openFromNotification);
      _openPage = open?..addListener(_openFromNotification);
      _openFromNotification();
    }
  }

  @override
  void dispose() {
    _openPage?.removeListener(_openFromNotification);
    super.dispose();
  }

  /// A tapped notification opens its page.
  void _openFromNotification() {
    final label = _openPage?.value;
    if (label == null) return;
    _openPage!.value = null;
    final i = pageIndex(label);
    if (i >= 0 && mounted) setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    // Phones get a drawer; wider windows keep the rail always visible.
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      appBar: AppBar(
        title: Text(narrow ? _pages[_index].$2 : 'Pilot Logbook'),
        actions: [
          _AlertCounts(
            onOpen: (label) => setState(() => _index = pageIndex(label)),
          ),
          NotificationBell(
            onOpen: (label) => setState(() => _index = pageIndex(label)),
          ),
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
                for (final (icon, label, _) in _pages)
                  NavigationDrawerDestination(
                    icon: Icon(icon),
                    label: Text(label),
                  ),
              ],
            )
          : null,
      body: Column(
        children: [
          const UpdateBanner(),
          Expanded(
            child: narrow
                ? _page()
                : Row(
                    children: [
                      // Scrolls when the window is too low for every item.
                      LayoutBuilder(
                        builder: (context, constraints) =>
                            SingleChildScrollView(
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
                                      for (final (icon, label, _) in _pages)
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
          ),
        ],
      ),
    );
  }
}

/// Counts at the top of the app that need someone: drones due for
/// maintenance, competencies expired or running out. Tapping one opens its
/// page ([onOpen] gets the page's label).
class _AlertCounts extends StatelessWidget {
  const _AlertCounts({required this.onOpen});
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => DbBuilder(
    builder: (context) {
      final services = Services.of(context);
      final drones = MaintenanceLog(services.db).dueCount();
      final competencies = CompetencyLog(services.db).alerts().length;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (drones > 0)
            _AlertCount(
              key: const Key('alert-maintenance'),
              icon: Icons.engineering,
              count: drones,
              tooltip: drones == 1
                  ? '1 drone or battery set due for maintenance'
                  : '$drones drones or battery sets due for maintenance',
              onTap: () => onOpen('Maintenance'),
            ),
          if (competencies > 0)
            _AlertCount(
              key: const Key('alert-competencies'),
              icon: Icons.verified_user,
              count: competencies,
              tooltip: competencies == 1
                  ? '1 competency expired or running out'
                  : '$competencies competencies expired or running out',
              onTap: () => onOpen('Competencies'),
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
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    color: Colors.white,
    onPressed: onTap,
    // A small gold count on the icon, so the page title still fits on a
    // phone.
    icon: Badge(
      backgroundColor: AppPalette.gold,
      textColor: AppPalette.text,
      label: Text(
        '$count',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      child: Icon(icon),
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
