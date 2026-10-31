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

/// Flights, flight time, aborted missions and near misses of one group:
/// a pilot, a project, a drone, a month...
class FlightStat {
  const FlightStat(
    this.id,
    this.name, {
    required this.flights,
    required this.seconds,
    this.aborted = 0,
    this.nearMisses = 0,
  });
  final String id;
  final String name;
  final int flights;
  final int seconds;
  final int aborted;
  final int nearMisses;

  /// Average flight time, or null when no flight has a time.
  int? get averageSeconds => flights == 0 ? null : seconds ~/ flights;
}

/// Figures over all flights for the top of the Statistic page.
class FlightTotals {
  const FlightTotals({
    required this.all,
    required this.days,
    required this.longestSeconds,
    required this.firstDate,
    required this.lastDate,
  });
  final FlightStat all;

  /// Days with at least one flight.
  final int days;
  final int longestSeconds;
  final String? firstDate;
  final String? lastDate;
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

  /// Flights and flight time per remote pilot (RP), most flights first.
  List<FlightStat> pilotStats() => _stats(
    'f.rp_id',
    join: 'JOIN people g ON g.id = f.rp_id',
    name: 'g.name',
  );

  /// Flights per spotter.
  List<FlightStat> spotterStats() => _stats(
    'f.spotter_id',
    join: 'JOIN people g ON g.id = f.spotter_id',
    name: 'g.name',
  );

  /// Per project; flights without one are under "No project".
  List<FlightStat> projectStats() => _stats(
    "COALESCE(f.project_id, '')",
    join: 'LEFT JOIN projects g ON g.id = f.project_id',
    name: "COALESCE(g.name, 'No project')",
  );

  /// Per drone.
  List<FlightStat> droneStats() => _stats(
    "COALESCE(f.aircraft_id, '')",
    join: 'LEFT JOIN aircraft g ON g.id = f.aircraft_id',
    name: "COALESCE(g.name, 'No drone')",
  );

  /// Cargo and inspection flights.
  List<FlightStat> kindStats() => _stats(
    "COALESCE(f.kind, '')",
    name: "COALESCE(NULLIF(f.kind, ''), 'Other')",
  );

  /// Per month (yyyy-MM), newest first.
  List<FlightStat> monthStats() => _stats(
    'substr(f.date, 1, 7)',
    name: 'substr(f.date, 1, 7)',
    where: "f.date LIKE '____-__%'",
    orderBy: 'name DESC',
  );

  FlightTotals totals() {
    final r = db
        .select(
          'SELECT COUNT(*) AS n, COALESCE(SUM(duration_s), 0) AS s, '
          'COALESCE(SUM(aborted = 1), 0) AS a, '
          'COALESCE(SUM(near_miss = 1), 0) AS m, '
          "COUNT(DISTINCT NULLIF(date, '')) AS d, "
          'COALESCE(MAX(duration_s), 0) AS l, '
          "MIN(NULLIF(date, '')) AS first, MAX(NULLIF(date, '')) AS last "
          'FROM flights WHERE deleted = 0',
        )
        .single;
    return FlightTotals(
      all: FlightStat(
        '',
        'All',
        flights: r['n'] as int,
        seconds: r['s'] as int,
        aborted: r['a'] as int,
        nearMisses: r['m'] as int,
      ),
      days: r['d'] as int,
      longestSeconds: r['l'] as int,
      firstDate: r['first'] as String?,
      lastDate: r['last'] as String?,
    );
  }

  /// Flights grouped by the SQL expression [key], most flights first.
  List<FlightStat> _stats(
    String key, {
    String join = '',
    required String name,
    String? where,
    String orderBy = 'n DESC, name',
  }) => [
    for (final r in db.select(
      'SELECT $key AS k, $name AS name, COUNT(f.id) AS n, '
      'COALESCE(SUM(f.duration_s), 0) AS s, '
      'COALESCE(SUM(f.aborted = 1), 0) AS a, '
      'COALESCE(SUM(f.near_miss = 1), 0) AS m '
      'FROM flights f $join '
      'WHERE f.deleted = 0${where == null ? '' : ' AND $where'} '
      'GROUP BY k ORDER BY $orderBy',
    ))
      FlightStat(
        r['k'] as String,
        (r['name'] as String?) ?? '',
        flights: r['n'] as int,
        seconds: r['s'] as int,
        aborted: r['a'] as int,
        nearMisses: r['m'] as int,
      ),
  ];
}
