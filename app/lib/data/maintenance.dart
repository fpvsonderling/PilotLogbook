/// Drone maintenance: a technician goes through the drone's assemblies and
/// writes "Checked" or what was done, one column per assembly, like the old
/// AppSheet "Maintenance" sheet.
library;

import 'local_db.dart';
import 'schema.dart';

const checkedValue = 'Checked';

class MaintenanceSection {
  const MaintenanceSection(this.column, this.title);

  /// Column in the maintenance table.
  final String column;
  final String title;
}

/// The assemblies of the old AppSheet sheet, in its order.
const maintenanceSections = [
  MaintenanceSection('arm_assembly', 'Arm Assembly'),
  MaintenanceSection('center_plate', 'Center Plate'),
  MaintenanceSection('propulsion_system', 'Propulsion System'),
  MaintenanceSection('load_assembly', 'Load Assembly'),
  MaintenanceSection('leg_assembly', 'Leg Assembly'),
  MaintenanceSection('power_system', 'Power System'),
  MaintenanceSection('fts', 'FTS'),
];

/// True when the stored value says only that the assembly was checked.
bool isJustChecked(Object? value) =>
    (value?.toString().trim().toLowerCase() ?? '') ==
    checkedValue.toLowerCase();

/// One saved maintenance.
class Maintenance {
  const Maintenance(this.row);
  final DbRow row;

  String get id => row['id'] as String;
  String get performedAt => row['performed_at'] as String? ?? '';
  String? get aircraftId => row['aircraft_id'] as String?;

  String value(MaintenanceSection s) => row[s.column]?.toString().trim() ?? '';

  /// Assemblies that were checked or worked on.
  List<MaintenanceSection> get done => [
    for (final s in maintenanceSections)
      if (value(s).isNotEmpty) s,
  ];

  /// Assemblies with a note of the work done (not just "Checked").
  List<(MaintenanceSection, String)> get work => [
    for (final s in maintenanceSections)
      if (value(s).isNotEmpty && !isJustChecked(value(s))) (s, value(s)),
  ];
}

/// Where a drone is since its last maintenance.
class DroneMaintenance {
  const DroneMaintenance({
    required this.aircraftId,
    required this.name,
    this.last,
    required this.flightsSince,
    required this.secondsSince,
  });

  final String aircraftId;
  final String name;

  /// The latest maintenance, null when there is none.
  final Maintenance? last;

  /// Flights after [last] (all flights when there is none).
  final int flightsSince;
  final int secondsSince;
}

/// Maintenance queries on top of [LocalDb].
class MaintenanceLog {
  MaintenanceLog(this.db);
  final LocalDb db;

  /// Newest first.
  List<Maintenance> all({String? aircraftId}) => [
    for (final r in db.rows(
      Tables.maintenance,
      where: aircraftId == null ? null : 'aircraft_id = ?',
      args: aircraftId == null ? const [] : [aircraftId],
      orderBy: 'performed_at DESC',
    ))
      Maintenance(r),
  ];

  /// Every active drone with its last maintenance and the flying since,
  /// the longest without maintenance first.
  List<DroneMaintenance> drones() {
    final latest = <String, Maintenance>{};
    for (final m in all()) {
      if (m.aircraftId != null) latest.putIfAbsent(m.aircraftId!, () => m);
    }
    final out = <DroneMaintenance>[];
    for (final a in db.rows(
      Tables.aircraft,
      where: 'COALESCE(active, 1) = 1',
      orderBy: 'name COLLATE NOCASE',
    )) {
      final id = a['id'] as String;
      final last = latest[id];
      // A flight on the maintenance day counts when it took off after it.
      final since = last?.performedAt ?? '';
      final r = db.select(
        'SELECT COUNT(*) AS n, COALESCE(SUM(duration_s), 0) AS s '
        'FROM flights WHERE deleted = 0 AND aircraft_id = ? AND '
        "(date || ' ' || COALESCE(NULLIF(takeoff_at, ''), '23:59:59')) > ?",
        [id, since],
      ).single;
      out.add(
        DroneMaintenance(
          aircraftId: id,
          name: a['name'] as String? ?? '',
          last: last,
          flightsSince: r['n'] as int,
          secondsSince: r['s'] as int,
        ),
      );
    }
    out.sort((a, b) {
      if ((a.last == null) != (b.last == null)) return a.last == null ? -1 : 1;
      return b.secondsSince.compareTo(a.secondsSince);
    });
    return out;
  }
}
