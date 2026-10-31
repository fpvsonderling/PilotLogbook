import 'checklists.dart';
import 'local_db.dart';
import 'schema.dart';
import 'table_filter.dart';

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

/// Tags in a flight's "What" (mission) field, which lists them comma
/// separated as in AppSheet: "Double, Aborted", "Sandra Delivery, Near miss".
/// The aborted / near_miss columns are kept in step with them.
enum MissionTag {
  aborted('Aborted', 'aborted', '%abort%'),
  nearMiss('Near miss', 'near_miss', '%near%miss%');

  const MissionTag(this.label, this.column, this._like);
  final String label;
  final String column;
  final String _like;

  RegExp get _pattern =>
      RegExp(_like.replaceAll('%', '.*'), caseSensitive: false);

  bool isIn(String? mission) => _pattern.hasMatch(mission ?? '');

  /// [mission] with this tag added or taken out.
  String setIn(String mission, bool on) {
    final parts = [
      for (final p in mission.split(','))
        if (p.trim().isNotEmpty && !_pattern.hasMatch(p)) p.trim(),
    ];
    if (on) parts.add(label);
    return parts.join(', ');
  }

  /// SQL: the flight [f] has the tag, by its column or its What field.
  String sql(String f) =>
      "($f.$column = 1 OR LOWER(COALESCE($f.mission, '')) LIKE '$_like')";
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
  List<FlightStat> pilotStats([TableFilter? filter]) => _stats(
    filter,
    'f.rp_id',
    join: 'JOIN people g ON g.id = f.rp_id',
    name: 'g.name',
  );

  /// Flights per spotter.
  List<FlightStat> spotterStats([TableFilter? filter]) => _stats(
    filter,
    'f.spotter_id',
    join: 'JOIN people g ON g.id = f.spotter_id',
    name: 'g.name',
  );

  /// Per project; flights without one are under "No project".
  List<FlightStat> projectStats([TableFilter? filter]) => _stats(
    filter,
    "COALESCE(f.project_id, '')",
    join: 'LEFT JOIN projects g ON g.id = f.project_id',
    name: "COALESCE(g.name, 'No project')",
  );

  /// Per drone.
  List<FlightStat> droneStats([TableFilter? filter]) => _stats(
    filter,
    "COALESCE(f.aircraft_id, '')",
    join: 'LEFT JOIN aircraft g ON g.id = f.aircraft_id',
    name: "COALESCE(g.name, 'No drone')",
  );

  /// Cargo and inspection flights.
  List<FlightStat> kindStats([TableFilter? filter]) => _stats(
    filter,
    "COALESCE(f.kind, '')",
    name: "COALESCE(NULLIF(f.kind, ''), 'Other')",
  );

  /// Per month (yyyy-MM), newest first.
  List<FlightStat> monthStats([TableFilter? filter]) => _stats(
    filter,
    'substr(f.date, 1, 7)',
    name: 'substr(f.date, 1, 7)',
    where: "f.date LIKE '____-__%'",
    orderBy: 'name DESC',
  );

  FlightTotals totals([TableFilter? filter]) {
    final (where, args) = statsScope(filter);
    final r = db
        .select(
          'SELECT COUNT(*) AS n, COALESCE(SUM(duration_s), 0) AS s, '
          'COALESCE(SUM(${MissionTag.aborted.sql('f')}), 0) AS a, '
          'COALESCE(SUM(${MissionTag.nearMiss.sql('f')}), 0) AS m, '
          "COUNT(DISTINCT NULLIF(date, '')) AS d, "
          'COALESCE(MAX(duration_s), 0) AS l, '
          "MIN(NULLIF(date, '')) AS first, MAX(NULLIF(date, '')) AS last "
          'FROM flights f WHERE f.deleted = 0$where',
          args,
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
    TableFilter? filter,
    String key, {
    String join = '',
    required String name,
    String? where,
    String orderBy = 'n DESC, name',
  }) {
    final (scope, args) = statsScope(filter);
    return [
      for (final r in db.select(
        'SELECT $key AS k, $name AS name, COUNT(f.id) AS n, '
        'COALESCE(SUM(f.duration_s), 0) AS s, '
        'COALESCE(SUM(${MissionTag.aborted.sql('f')}), 0) AS a, '
        'COALESCE(SUM(${MissionTag.nearMiss.sql('f')}), 0) AS m '
        'FROM flights f $join '
        'WHERE f.deleted = 0${where == null ? '' : ' AND $where'}$scope '
        'GROUP BY k ORDER BY $orderBy',
        args,
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

  /// The Statistic page's filter as SQL on the flight `f`: the dates and
  /// the [statsFields] chosen. Search text is not used there.
  static (String, List<Object?>) statsScope(TableFilter? filter) {
    if (filter == null) return ('', const []);
    final sql = StringBuffer();
    final args = <Object?>[];
    if (filter.from != null) {
      sql.write(' AND substr(f.date, 1, 10) >= ?');
      args.add(filter.from);
    }
    if (filter.to != null) {
      sql.write(' AND substr(f.date, 1, 10) <= ?');
      args.add(filter.to);
    }
    for (final e in filter.chosen.entries) {
      switch (e.key) {
        case 'project':
          sql.write(' AND f.project_id = ?');
          args.add(e.value);
        case 'drone':
          sql.write(' AND f.aircraft_id = ?');
          args.add(e.value);
        case 'pilot':
          sql.write(' AND ? IN (f.rp_id, f.pa_id, f.spotter_id)');
          args.add(e.value);
        case 'kind':
          sql.write(' AND f.kind = ?');
          args.add(e.value);
      }
    }
    return (sql.toString(), args);
  }

  /// What the Statistic page can be filtered by, with the same keys as
  /// [statsScope].
  static final statsFields = <FilterField<DbRow>>[
    FilterField('project', 'Project', (f) => [f['project_id'] as String?]),
    FilterField('drone', 'Drone', (f) => [f['aircraft_id'] as String?]),
    FilterField(
      'pilot',
      'Pilot',
      (f) => [
        f['rp_id'] as String?,
        f['pa_id'] as String?,
        f['spotter_id'] as String?,
      ],
    ),
    FilterField('kind', 'Cargo / Inspection', (f) => [f['kind'] as String?]),
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
