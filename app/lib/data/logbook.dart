import 'checklists.dart';
import 'local_db.dart';
import 'schema.dart';

/// Seconds between two HH:mm[:ss] times; a landing before take-off is taken
/// as the next day. Null when either time cannot be read.
int? flightSeconds(String? takeoff, String? landing) {
  final a = parseTimeOfDay(takeoff);
  final b = parseTimeOfDay(landing);
  if (a == null || b == null) return null;
  final d = b - a;
  return d >= 0 ? d : d + 24 * 3600;
}

/// Seconds since midnight for "H:mm", "HH:mm" or "HH:mm:ss".
int? parseTimeOfDay(String? s) {
  if (s == null) return null;
  final parts = s.trim().split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final n = parts.map(int.tryParse).toList();
  if (n.any((v) => v == null)) return null;
  final h = n[0]!, m = n[1]!, sec = parts.length == 3 ? n[2]! : 0;
  if (h > 23 || m > 59 || sec > 59 || h < 0 || m < 0 || sec < 0) return null;
  return h * 3600 + m * 60 + sec;
}

/// 3810 -> "1:03:30"
String formatDuration(int? seconds) {
  if (seconds == null) return '';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// One saved daily check and the checklist it was made with.
class DailyCheck {
  const DailyCheck(this.checklist, this.row);
  final Checklist checklist;
  final DbRow row;

  String get id => row['id'] as String;
  String get checkedAt => row['checked_at'] as String? ?? '';

  /// Sections marked as a problem, with the pilot's note.
  List<(ChecklistSection, String)> get problems => [
    for (final s in checklist.sections)
      if (sectionResult(row[s.column]) == SectionResult.problem)
        (s, row[s.column].toString()),
  ];
}

class PilotStat {
  const PilotStat(this.personId, this.name, this.flights, this.seconds);
  final String personId;
  final String name;
  final int flights;
  final int seconds;
}

/// Queries the screens need, on top of [LocalDb].
class Logbook {
  Logbook(this.db);
  final LocalDb db;

  /// A reference table as id -> name, sorted by name. [activeOnly] gives
  /// the pickers' list; otherwise deleted rows are in too, so old flights
  /// and checks keep showing a deleted drone's or person's name.
  Map<String, String> names(TableDef table, {bool activeOnly = false}) => {
    for (final r
        in activeOnly
            ? db.rows(
                table,
                where: 'COALESCE(active, 1) = 1',
                orderBy: 'name COLLATE NOCASE',
              )
            : db.select(
                'SELECT id, name FROM ${table.name} ORDER BY name COLLATE NOCASE',
              ))
      r['id'] as String: (r['name'] as String?) ?? '',
  };

  /// People whose roles include [role] (pilot, spotter, ...).
  Map<String, String> peopleWithRole(String role) => {
    for (final r in db.rows(
      Tables.people,
      where: "COALESCE(active, 1) = 1 AND (',' || REPLACE(COALESCE(roles, ''), ' ', '') || ',') LIKE ?",
      args: ['%,$role,%'],
      orderBy: 'name COLLATE NOCASE',
    ))
      r['id'] as String: (r['name'] as String?) ?? '',
  };

  List<DbRow> flights({String? kind}) => db.rows(
    Tables.flights,
    where: kind == null ? null : 'kind = ?',
    args: kind == null ? const [] : [kind],
    orderBy: 'date DESC, takeoff_at DESC',
  );

  /// Daily checks of every drone type, newest first.
  List<DailyCheck> dailyChecks({String? aircraftId, int? limit}) {
    final all = [
      for (final c in checklists)
        for (final r in db.rows(
          c.table,
          where: aircraftId == null ? null : 'aircraft_id = ?',
          args: aircraftId == null ? const [] : [aircraftId],
        ))
          DailyCheck(c, r),
    ]..sort((a, b) => b.checkedAt.compareTo(a.checkedAt));
    return limit == null || all.length <= limit ? all : all.sublist(0, limit);
  }

  /// Problems found in the last [checks] daily checks of a drone, to review
  /// before powering it on. [exceptId] leaves out the check being edited.
  List<(DailyCheck, ChecklistSection, String)> recentProblems(
    String aircraftId, {
    String? exceptId,
    int checks = 3,
  }) => [
    for (final c in dailyChecks(
      aircraftId: aircraftId,
    ).where((c) => c.id != exceptId).take(checks))
      for (final (section, note) in c.problems) (c, section, note),
  ];

  /// Every fault, open ones first, then by class (grounded first) and newest.
  List<FaultCase> faultCases({String? aircraftId}) {
    Map<String, List<DbRow>> byFault(TableDef t, String orderBy) {
      final out = <String, List<DbRow>>{};
      for (final r in db.rows(t, orderBy: orderBy)) {
        out.putIfAbsent(r['fault_id'] as String? ?? '', () => []).add(r);
      }
      return out;
    }

    final repairs = byFault(
      Tables.faultRepairs,
      "COALESCE(NULLIF(finished_at, ''), started_at), updated_at",
    );
    final signoffs = byFault(Tables.faultSignoffs, 'tested_at, updated_at');
    final photos = byFault(Tables.faultPhotos, 'updated_at');
    final cases = [
      for (final f in db.rows(
        Tables.faults,
        where: aircraftId == null ? null : 'aircraft_id = ?',
        args: aircraftId == null ? const [] : [aircraftId],
      ))
        FaultCase(
          f,
          repairs[f['id']] ?? const [],
          signoffs[f['id']] ?? const [],
          photos[f['id']] ?? const [],
        ),
    ];
    cases.sort((a, b) {
      final s = a.status.index.compareTo(b.status.index);
      if (s != 0) return s;
      if (a.status != FaultStatus.closed) {
        final c = b.severity.compareTo(a.severity);
        if (c != 0) return c;
      }
      return b.reportedAt.compareTo(a.reportedAt);
    });
    return cases;
  }

  FaultCase? faultCase(String id) =>
      faultCases().where((c) => c.id == id).firstOrNull;

  /// Flights and flight time per remote pilot (RP), most flights first.
  List<PilotStat> pilotStats() => _stats('rp_id', withTime: true);

  /// Flights per spotter.
  List<PilotStat> spotterStats() => _stats('spotter_id', withTime: false);

  List<PilotStat> _stats(String column, {required bool withTime}) => [
    for (final r in db.select(
      'SELECT p.id, p.name, COUNT(f.id) AS n, '
      'COALESCE(SUM(f.duration_s), 0) AS s '
      'FROM flights f JOIN people p ON p.id = f.$column '
      'WHERE f.deleted = 0 '
      'GROUP BY p.id ORDER BY n DESC, p.name',
    ))
      PilotStat(
        r['id'] as String,
        (r['name'] as String?) ?? '',
        r['n'] as int,
        withTime ? r['s'] as int : 0,
      ),
  ];
}

enum FaultStatus { open, repaired, closed }

/// One fault with everything done about it: repairs, test sign-offs and
/// photos, each its own row (see Tables.faults).
class FaultCase {
  FaultCase(this.fault, this.repairs, this.signoffs, this.photos);

  final DbRow fault;

  /// Oldest first, like [signoffs].
  final List<DbRow> repairs;
  final List<DbRow> signoffs;
  final List<DbRow> photos;

  String get id => fault['id'] as String;
  String get reportedAt => fault['reported_at'] as String? ?? '';
  int get severity => fault['severity'] as int? ?? 0;

  static String repairTime(DbRow r) =>
      (r['finished_at'] as String?)?.isNotEmpty == true
      ? r['finished_at'] as String
      : r['started_at'] as String? ?? '';

  DbRow? get passedSignoff =>
      signoffs.where((s) => s['result'] == 'pass').lastOrNull;

  /// Closed once a test passed. Otherwise repaired (waiting for the test)
  /// when the last repair came after the last failed test.
  FaultStatus get status {
    if (passedSignoff != null) return FaultStatus.closed;
    if (repairs.isEmpty) return FaultStatus.open;
    final failedAt = signoffs.lastOrNull?['tested_at'] as String? ?? '';
    return repairTime(repairs.last).compareTo(failedAt) > 0
        ? FaultStatus.repaired
        : FaultStatus.open;
  }

  /// A class 3 fault keeps the drone on the ground until a test passes.
  bool get grounded => severity == 3 && status != FaultStatus.closed;

  /// Photos of the report, or of one repair when [repairId] is given.
  List<DbRow> photosOf([String? repairId]) => [
    for (final p in photos)
      if ((p['repair_id'] as String? ?? '') == (repairId ?? '')) p,
  ];
}
