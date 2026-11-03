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

/// How often an assembly is due: after [hours] of flight, [flights]
/// flights or [days] days since it was last done, whichever comes first.
/// Null means that limit is not used; all three null, no reminder.
class MaintenanceInterval {
  const MaintenanceInterval({this.hours, this.flights, this.days});
  final double? hours;
  final int? flights;
  final int? days;

  bool get isOff => hours == null && flights == null && days == null;

  /// "10 h · 90 days", "Off".
  String describe() {
    if (isOff) return 'Off';
    String n(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';
    return [
      if (hours != null) '${n(hours!)} h',
      if (flights != null) '$flights flights',
      if (days != null) '$days days',
    ].join(' · ');
  }
}

/// Intervals of the FB3 UAS Maintenance Manual 2.4.8, Maintenance Planning
/// Document (page 9), for each assembly the most frequent task in it:
/// - Arm, Center Plate, Leg (landing gear): torque check every 20 flight
///   hours or 6 months.
/// - Propulsion: propeller GVI every 10 flight hours or 3 months (motor
///   mounts 20 h / 6 months, bearings 500 h).
/// - Load: remote controlled load hook GVI every 10 flight hours or 3
///   months (load attachment torque 20 h / 6 months).
/// - Power: batteries GVI every 10 flight hours or 3 months.
/// - FTS: DVI every 1000 cycles or 6 months; FTS cycles are not logged, so
///   only the 6 months.
/// Admins change them under Reference data > Maintenance intervals.
const bookIntervals = <String, MaintenanceInterval>{
  'arm_assembly': MaintenanceInterval(hours: 20, days: 182),
  'center_plate': MaintenanceInterval(hours: 20, days: 182),
  'propulsion_system': MaintenanceInterval(hours: 10, days: 91),
  'load_assembly': MaintenanceInterval(hours: 10, days: 91),
  'leg_assembly': MaintenanceInterval(hours: 20, days: 182),
  'power_system': MaintenanceInterval(hours: 10, days: 91),
  'fts': MaintenanceInterval(days: 182),
};

/// From 80 % of an interval an assembly shows as due soon.
const dueSoonShare = 0.8;

enum DueLevel { ok, soon, overdue }

/// One assembly of one drone against its interval.
class SectionDue {
  const SectionDue({
    required this.section,
    required this.interval,
    required this.lastAt,
    required this.flightsSince,
    required this.secondsSince,
    required this.daysSince,
  });

  final MaintenanceSection section;
  final MaintenanceInterval interval;

  /// When the assembly was last checked or worked on; null: never.
  final String? lastAt;
  final int flightsSince;
  final int secondsSince;

  /// Null when it was never done: then only the flying counts.
  final int? daysSince;

  /// The largest share of a limit used up: 1.0 means due now.
  double get used {
    var share = 0.0;
    final i = interval;
    if (i.hours != null && i.hours! > 0) {
      share = _max(share, secondsSince / 3600 / i.hours!);
    }
    if (i.flights != null && i.flights! > 0) {
      share = _max(share, flightsSince / i.flights!);
    }
    if (i.days != null && i.days! > 0 && daysSince != null) {
      share = _max(share, daysSince! / i.days!);
    }
    return share;
  }

  DueLevel get level {
    if (interval.isOff) return DueLevel.ok;
    final u = used;
    if (u >= 1) return DueLevel.overdue;
    if (u >= dueSoonShare) return DueLevel.soon;
    return DueLevel.ok;
  }

  /// What is left, or how far over: "2:30 h left", "5 days over".
  String describe() {
    final i = interval;
    final parts = <String>[];
    if (i.hours != null) {
      final left = (i.hours! * 3600).round() - secondsSince;
      parts.add(left >= 0 ? '${_hm(left)} h left' : '${_hm(-left)} h over');
    }
    if (i.flights != null) {
      final left = i.flights! - flightsSince;
      parts.add(left >= 0 ? '$left flights left' : '${-left} flights over');
    }
    if (i.days != null && daysSince != null) {
      final left = i.days! - daysSince!;
      parts.add(left >= 0 ? '$left days left' : '${-left} days over');
    }
    return parts.join(' · ');
  }
}

double _max(double a, double b) => a > b ? a : b;

String _hm(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return '$h:${m.toString().padLeft(2, '0')}';
}

/// Where a drone is since its last maintenance.
class DroneMaintenance {
  const DroneMaintenance({
    required this.aircraftId,
    required this.name,
    this.last,
    required this.flightsSince,
    required this.secondsSince,
    this.sections = const [],
  });

  final String aircraftId;
  final String name;

  /// The latest maintenance, null when there is none.
  final Maintenance? last;

  /// Flights after [last] (all flights when there is none).
  final int flightsSince;
  final int secondsSince;

  /// Every assembly against its interval.
  final List<SectionDue> sections;

  /// The worst of [sections].
  DueLevel get level => sections.fold(
    DueLevel.ok,
    (l, s) => s.level.index > l.index ? s.level : l,
  );

  /// Assemblies due soon or overdue, the most urgent first.
  List<SectionDue> get due => [
    for (final s in sections)
      if (s.level != DueLevel.ok) s,
  ]..sort((a, b) => b.used.compareTo(a.used));
}

/// Maintenance queries on top of [LocalDb].
class MaintenanceLog {
  MaintenanceLog(this.db, {DateTime Function()? today})
    : today = today ?? DateTime.now;
  final LocalDb db;
  final DateTime Function() today;

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

  /// The admin's interval rows, as (model in lower case, section) -> row.
  Map<(String, String), DbRow> _intervalRows() => {
    for (final r in db.rows(Tables.maintenanceIntervals, orderBy: 'updated_at'))
      (
        (r['model'] as String? ?? '').trim().toLowerCase(),
        r['section'] as String? ?? '',
      ): r,
  };

  static MaintenanceInterval _fromRow(DbRow r) => MaintenanceInterval(
    hours: (r['hours'] as num?)?.toDouble(),
    flights: r['flights'] as int?,
    days: r['days'] as int?,
  );

  /// The interval of [section] for a drone of [model]: the admin's row for
  /// that model, else their row for every drone, else the book's.
  MaintenanceInterval interval(
    String section, {
    String? model,
    Map<(String, String), DbRow>? rows,
  }) {
    rows ??= _intervalRows();
    final m = (model ?? '').trim().toLowerCase();
    final own = m.isEmpty ? null : rows[(m, section)];
    if (own != null) return _fromRow(own);
    final all = rows[('', section)];
    if (all != null) return _fromRow(all);
    return bookIntervals[section] ?? const MaintenanceInterval();
  }

  /// Flights of a drone that took off after [since] ('' = all of them).
  /// A flight on the maintenance day counts when it took off after it.
  (int, int) _flyingSince(String aircraftId, String since) {
    final r = db.select(
      'SELECT COUNT(*) AS n, COALESCE(SUM(duration_s), 0) AS s '
      'FROM flights WHERE deleted = 0 AND aircraft_id = ? AND '
      "(date || ' ' || COALESCE(NULLIF(takeoff_at, ''), '23:59:59')) > ?",
      [aircraftId, since],
    ).single;
    return (r['n'] as int, r['s'] as int);
  }

  int? _daysSince(String? at) {
    if (at == null || at.isEmpty) return null;
    final d = DateTime.tryParse(at.split(' ').first);
    if (d == null) return null;
    final now = today();
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(d.year, d.month, d.day)).inDays;
  }

  /// Every active drone with its last maintenance, the flying since and
  /// each assembly against its interval; the most urgent first, then the
  /// longest without maintenance.
  List<DroneMaintenance> drones() {
    final history = all();
    final latest = <String, Maintenance>{};
    // Per drone and assembly the latest maintenance that did it.
    final lastDone = <(String, String), String>{};
    for (final m in history) {
      final a = m.aircraftId;
      if (a == null) continue;
      latest.putIfAbsent(a, () => m);
      for (final s in m.done) {
        lastDone.putIfAbsent((a, s.column), () => m.performedAt);
      }
    }
    final rows = _intervalRows();
    final out = <DroneMaintenance>[];
    for (final a in db.rows(
      Tables.aircraft,
      where: 'COALESCE(active, 1) = 1',
      orderBy: 'name COLLATE NOCASE',
    )) {
      final id = a['id'] as String;
      final last = latest[id];
      final cache = <String, (int, int)>{};
      (int, int) since(String at) =>
          cache.putIfAbsent(at, () => _flyingSince(id, at));
      final (n, s) = since(last?.performedAt ?? '');
      out.add(
        DroneMaintenance(
          aircraftId: id,
          name: a['name'] as String? ?? '',
          last: last,
          flightsSince: n,
          secondsSince: s,
          sections: [
            for (final sec in maintenanceSections)
              () {
                final at = lastDone[(id, sec.column)];
                final (fn, fs) = since(at ?? '');
                return SectionDue(
                  section: sec,
                  interval: interval(
                    sec.column,
                    model: a['model'] as String?,
                    rows: rows,
                  ),
                  lastAt: at,
                  flightsSince: fn,
                  secondsSince: fs,
                  daysSince: _daysSince(at),
                );
              }(),
          ],
        ),
      );
    }
    out.sort((a, b) {
      if (a.level != b.level) return b.level.index.compareTo(a.level.index);
      if ((a.last == null) != (b.last == null)) return a.last == null ? -1 : 1;
      return b.secondsSince.compareTo(a.secondsSince);
    });
    return out;
  }

  /// Drones with an assembly due soon or overdue.
  int dueCount() => drones().where((d) => d.level != DueLevel.ok).length;
}
