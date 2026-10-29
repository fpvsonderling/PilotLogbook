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

  /// Active rows of a reference table as id -> name, sorted by name.
  Map<String, String> names(TableDef table, {bool activeOnly = false}) => {
    for (final r in db.rows(
      table,
      where: activeOnly ? 'COALESCE(active, 1) = 1' : null,
      orderBy: 'name COLLATE NOCASE',
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
