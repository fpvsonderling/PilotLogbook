/// Projects (wind farms): where they are and links to their maps.
library;

import 'local_db.dart';

/// One place of a project: the farm, or one turbine of it.
class ProjectPoint {
  const ProjectPoint(this.lat, this.lon, [this.label = '']);
  final double lat;
  final double lon;
  final String label;

  /// "54.123456, 2.123456"
  String get text => '${_fixed(lat)}, ${_fixed(lon)}';

  String get mapsUrl =>
      'https://www.google.com/maps/search/?api=1&query=$lat%2C$lon';

  @override
  bool operator ==(Object other) =>
      other is ProjectPoint &&
      other.lat == lat &&
      other.lon == lon &&
      other.label == label;

  @override
  int get hashCode => Object.hash(lat, lon, label);

  static String _fixed(double v) {
    var t = v.toStringAsFixed(6);
    t = t.replaceFirst(RegExp(r'0+$'), '');
    return t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  }
}

final _pair = RegExp(r'(-?\d{1,3}(?:\.\d+)?)\s*[,;\s]\s*(-?\d{1,3}(?:\.\d+)?)');

/// Latitude and longitude in a Google Maps link: "@54.1,2.3,12z",
/// "?q=54.1,2.3", "query=54.1%2C2.3", "!3d54.1!4d2.3". Null when there are
/// none, e.g. a short maps.app.goo.gl link.
ProjectPoint? pointFromMapsUrl(String url) {
  final u = Uri.decodeFull(url.trim());
  final pin = RegExp(r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)').firstMatch(u);
  if (pin != null) return _point(pin.group(1)!, pin.group(2)!);
  for (final p in [
    RegExp(
      r'[?&](?:q|query|ll|center|destination)=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)',
    ),
    RegExp(r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)'),
    RegExp(r'/place/(-?\d+(?:\.\d+)?),\+?(-?\d+(?:\.\d+)?)'),
  ]) {
    final m = p.firstMatch(u);
    if (m != null) return _point(m.group(1)!, m.group(2)!);
  }
  return null;
}

ProjectPoint? _point(String lat, String lon, [String label = '']) {
  final a = double.tryParse(lat);
  final b = double.tryParse(lon);
  if (a == null || b == null || a.abs() > 90 || b.abs() > 180) return null;
  return ProjectPoint(a, b, label);
}

/// The points in a project's coordinates: one per line, "lat, lon",
/// "T01: lat, lon" or a Google Maps link. Lines that are neither are
/// returned in [bad].
({List<ProjectPoint> points, List<String> bad}) parseCoordinates(String? text) {
  final points = <ProjectPoint>[];
  final bad = <String>[];
  for (final raw in (text ?? '').split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    var label = '';
    var rest = line;
    final colon = RegExp(r'^([^:]*[A-Za-z][^:]*):\s*(.+)$').firstMatch(line);
    if (colon != null &&
        !RegExp(r'^(https?:|www\.)', caseSensitive: false).hasMatch(line)) {
      label = colon.group(1)!.trim();
      rest = colon.group(2)!.trim();
    }
    ProjectPoint? p;
    if (rest.contains('://') || rest.startsWith('www.')) {
      final fromUrl = pointFromMapsUrl(rest);
      if (fromUrl != null) p = ProjectPoint(fromUrl.lat, fromUrl.lon, label);
    } else {
      final m = _pair.firstMatch(rest);
      if (m != null && m.start == 0 && m.end == rest.length) {
        p = _point(m.group(1)!, m.group(2)!, label);
      }
    }
    p == null ? bad.add(line) : points.add(p);
  }
  return (points: points, bad: bad);
}

class Project {
  const Project(this.row);
  final DbRow row;

  String get id => row['id'] as String;
  String get name => (row['name'] as String? ?? '').trim();
  String get client => (row['client'] as String? ?? '').trim();
  String get country => (row['country'] as String? ?? '').trim();
  String get notes => (row['notes'] as String? ?? '').trim();
  String get zoneMapUrl => (row['zone_map_url'] as String? ?? '').trim();
  bool get active => (row['active'] as int? ?? 1) == 1;
  List<ProjectPoint> get points =>
      parseCoordinates(row['coordinates'] as String?).points;

  /// The admin's own Google Maps link, else one made from the first point;
  /// empty when there is neither.
  String get mapsUrl {
    final own = (row['maps_url'] as String? ?? '').trim();
    if (own.isNotEmpty) return own;
    final p = points;
    return p.isEmpty ? '' : p.first.mapsUrl;
  }
}
