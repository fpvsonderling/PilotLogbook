/// Weather before a flight: a forecast for the project's place, shown in
/// the flight form. Only a preview: nothing of it is saved with the flight
/// or synced. The last forecast of each place is kept on this device (48
/// hours ahead), so it can still be shown without internet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'local_db.dart';
import 'projects.dart';

/// One hour of the forecast.
class WeatherHour {
  const WeatherHour({
    required this.time,
    this.wind,
    this.gust,
    this.direction,
    this.temp,
    this.rain,
    this.rainChance,
    this.fog,
    this.humidity,
  });

  /// Start of the hour, UTC.
  final DateTime time;

  /// Wind at 10 m, m/s.
  final double? wind;

  /// Gusts at 10 m, m/s.
  final double? gust;

  /// Where the wind comes from, degrees (0 = from north).
  final double? direction;

  /// °C at 2 m.
  final double? temp;

  /// Rain in this hour, mm.
  final double? rain;

  /// Chance of rain in this hour, %.
  final double? rainChance;

  /// Part of the sky covered by fog, %.
  final double? fog;

  /// Relative humidity, %.
  final double? humidity;

  /// Gusts are about this many times the mean wind over land. Used only
  /// when the forecast has no gusts: MET Norway gives them for the Nordic
  /// countries only, so e.g. Spain comes without.
  static const gustFactor = 1.4;

  /// The gusts to show: the forecast's, else an estimate from the wind.
  double? get gustShown => gust ?? (wind == null ? null : wind! * gustFactor);

  /// [gustShown] is an estimate from the wind, not a forecast.
  bool get gustEstimated => gust == null && wind != null;

  Map<String, Object?> toJson() => {
    't': time.toIso8601String(),
    'w': wind,
    'g': gust,
    'd': direction,
    'c': temp,
    'r': rain,
    'rp': rainChance,
    'f': fog,
    'h': humidity,
  };

  static WeatherHour fromJson(Map<String, dynamic> j) => WeatherHour(
    time: DateTime.parse(j['t'] as String),
    wind: _num(j['w']),
    gust: _num(j['g']),
    direction: _num(j['d']),
    temp: _num(j['c']),
    rain: _num(j['r']),
    rainChance: _num(j['rp']),
    fog: _num(j['f']),
    humidity: _num(j['h']),
  );
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

/// A forecast for one place, as fetched at [fetchedAt].
class WeatherForecast {
  const WeatherForecast({
    required this.fetchedAt,
    required this.hours,
    this.kp = const {},
    this.source = 'MET Norway',
  });

  final DateTime fetchedAt;

  /// Hour by hour, oldest first.
  final List<WeatherHour> hours;

  /// Planetary Kp index for 3-hour blocks starting at the key (UTC).
  final Map<DateTime, double> kp;

  /// Shown on the card, e.g. "MET Norway".
  final String source;

  /// The hour [now] falls in; the nearest one when it is outside the
  /// forecast. Null when there are no hours.
  WeatherHour? at(DateTime now) {
    if (hours.isEmpty) return null;
    final t = now.toUtc();
    WeatherHour best = hours.first;
    for (final h in hours) {
      if (!h.time.isAfter(t)) best = h;
    }
    return best;
  }

  /// [count] hours from the one [now] falls in.
  List<WeatherHour> next(DateTime now, int count) {
    final current = at(now);
    if (current == null) return const [];
    final i = hours.indexOf(current);
    return hours.sublist(i, math.min(hours.length, i + count));
  }

  /// Kp for the 3-hour block [now] falls in.
  double? kpAt(DateTime now) {
    final t = now.toUtc();
    double? best;
    for (final e
        in kp.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      if (!e.key.isAfter(t)) best = e.value;
    }
    return best;
  }

  String toJsonString() => jsonEncode({
    'at': fetchedAt.toIso8601String(),
    'src': source,
    'hours': [for (final h in hours) h.toJson()],
    'kp': {for (final e in kp.entries) e.key.toIso8601String(): e.value},
  });

  static WeatherForecast? fromJsonString(String? text) {
    if (text == null || text.isEmpty) return null;
    try {
      final j = jsonDecode(text) as Map<String, dynamic>;
      return WeatherForecast(
        fetchedAt: DateTime.parse(j['at'] as String),
        source: j['src'] as String? ?? 'MET Norway',
        hours: [
          for (final h in j['hours'] as List)
            WeatherHour.fromJson(h as Map<String, dynamic>),
        ],
        kp: {
          for (final e in (j['kp'] as Map<String, dynamic>? ?? {}).entries)
            DateTime.parse(e.key): (e.value as num).toDouble(),
        },
      );
    } catch (_) {
      return null;
    }
  }
}

/// Reads MET Norway's locationforecast/2.0/complete answer.
/// https://api.met.no/weatherapi/locationforecast/2.0/documentation
List<WeatherHour> parseMetNorway(Map<String, dynamic> json) {
  final series = (json['properties'] as Map?)?['timeseries'] as List? ?? [];
  final hours = <WeatherHour>[];
  DateTime? last;
  for (final s in series) {
    final time = DateTime.tryParse(s['time'] as String? ?? '')?.toUtc();
    final data = s['data'] as Map?;
    if (time == null || data == null) continue;
    // Hourly at first, then 6-hourly: keep only the hourly part.
    if (last != null && time.difference(last) > const Duration(hours: 1)) {
      break;
    }
    last = time;
    final now = (data['instant'] as Map?)?['details'] as Map? ?? {};
    final next = (data['next_1_hours'] as Map?)?['details'] as Map? ?? {};
    hours.add(
      WeatherHour(
        time: time,
        wind: _num(now['wind_speed']),
        gust: _num(now['wind_speed_of_gust']),
        direction: _num(now['wind_from_direction']),
        temp: _num(now['air_temperature']),
        rain: _num(next['precipitation_amount']),
        rainChance: _num(next['probability_of_precipitation']),
        fog: _num(now['fog_area_fraction']),
        humidity: _num(now['relative_humidity']),
      ),
    );
  }
  return hours;
}

/// Reads NOAA SWPC's planetary K index forecast: rows of
/// [time_tag, kp, observed, noaa_scale] after a header row, or objects
/// with time_tag and kp.
Map<DateTime, double> parseKpForecast(Object? json) {
  final out = <DateTime, double>{};
  if (json is! List) return out;
  for (final row in json) {
    Object? time, kp;
    if (row is List && row.length >= 2) {
      (time, kp) = (row[0], row[1]);
    } else if (row is Map) {
      (time, kp) = (row['time_tag'], row['kp']);
    }
    final t = time is String
        ? DateTime.tryParse('${time.replaceFirst(' ', 'T')}Z')
        : null;
    final k = kp is num ? kp.toDouble() : double.tryParse('$kp');
    if (t != null && k != null) out[t.toUtc()] = k;
  }
  return out;
}

/// Where the weather is fetched for: the project's first point, else the
/// place in its own Google Maps link. Null when it has neither.
ProjectPoint? weatherPoint(Project project) {
  final points = project.points;
  if (points.isNotEmpty) return points.first;
  final url = (project.row['maps_url'] as String? ?? '').trim();
  return url.isEmpty ? null : pointFromMapsUrl(url);
}

/// Windy's forecast of the point, at the point.
String windyUrl(ProjectPoint p) {
  final lat = p.lat.toStringAsFixed(4);
  final lon = p.lon.toStringAsFixed(4);
  return 'https://www.windy.com/$lat/$lon?$lat,$lon,11';
}

/// "SW" for 225°.
String compass(double degrees) {
  const names = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
  return names[((degrees % 360) / 45).round() % 8];
}

/// What the drone may fly in. The wind and gust limits are set per drone
/// under Reference data; the rest are the same for all.
class WeatherLimits {
  const WeatherLimits({
    this.wind = defaultWind,
    this.gust = defaultGust,
    this.rain = 0.5,
    this.kp = 5,
  });

  static const defaultWind = 10.0;
  static const defaultGust = 12.0;

  /// m/s at 10 m.
  final double wind;
  final double gust;

  /// mm in an hour.
  final double rain;
  final double kp;

  /// The limits of a drone row: its max_wind_ms and max_gust_ms, or the
  /// defaults when they are empty.
  static WeatherLimits of(DbRow? drone) {
    double? read(String key) =>
        double.tryParse('${drone?[key] ?? ''}'.trim().replaceAll(',', '.'));
    return WeatherLimits(
      wind: read('max_wind_ms') ?? defaultWind,
      gust: read('max_gust_ms') ?? defaultGust,
    );
  }

  /// What is over the limits in [h] (and [kpNow]); empty when all is fine.
  List<String> problems(WeatherHour h, double? kpNow) => [
    if ((h.wind ?? 0) > wind) 'Wind above ${fmt(wind)} m/s',
    if ((h.gustShown ?? 0) > gust)
      h.gustEstimated
          ? 'Gusts (est.) above ${fmt(gust)} m/s'
          : 'Gusts above ${fmt(gust)} m/s',
    if ((h.rain ?? 0) > rain) 'Rain',
    if ((kpNow ?? 0) >= kp) 'Kp ${fmt(kpNow!)}: GPS may be poor',
  ];

  /// "12", "0.5", "2.3".
  static String fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Fetches forecasts and keeps the last one of each place on this device.
class WeatherService {
  WeatherService(
    this.db, {
    http.Client? client,
    DateTime Function()? clock,
    this.freshFor = const Duration(minutes: 30),
  }) : _given = client,
       _clock = clock ?? DateTime.now;

  final LocalDb db;
  final http.Client? _given;
  http.Client? _made;
  final DateTime Function() _clock;

  /// A forecast younger than this is not fetched again.
  final Duration freshFor;

  /// A kept forecast older than this is thrown away.
  static const keepFor = Duration(hours: 48);

  static const metUrl =
      'https://api.met.no/weatherapi/locationforecast/2.0/complete';
  static const kpUrl =
      'https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json';

  /// MET Norway asks every app to say who it is.
  static const userAgent =
      'PilotLogbook/1.0 github.com/fpvsonderling/PilotLogbook';

  static String _key(ProjectPoint p) =>
      'weather:${p.lat.toStringAsFixed(2)},${p.lon.toStringAsFixed(2)}';

  DateTime now() => _clock();

  /// Why the last fetch failed, in a few words; null when it worked.
  String? lastError;

  /// Windows only trusts the root certificates it has already fetched for
  /// some other program, and Dart does not ask it to fetch more. MET
  /// Norway's certificate (HARICA) is often not among them, so on Windows
  /// the app brings its own list of roots (Mozilla's, as in curl and
  /// Firefox) on top of the system ones.
  Future<http.Client> _client() async {
    final given = _given;
    if (given != null) return given;
    final made = _made;
    if (made != null) return made;
    http.Client client = http.Client();
    if (Platform.isWindows) {
      try {
        final pem = await rootBundle.load('assets/certs/cacert.pem');
        final context = SecurityContext(withTrustedRoots: true)
          ..setTrustedCertificatesBytes(pem.buffer.asUint8List());
        client = IOClient(HttpClient(context: context));
      } catch (_) {
        // Without the list: the system roots only.
      }
    }
    return _made = client;
  }

  /// "certificate", "timeout", "HTTP 403": what went wrong, for the card.
  static String describe(Object e) => switch (e) {
    HandshakeException() || TlsException() => 'certificate error',
    TimeoutException() => 'timeout',
    SocketException() => 'no connection',
    http.ClientException(:final message) =>
      message.contains('CERTIFICATE') || message.contains('Handshake')
          ? 'certificate error'
          : 'no connection',
    _ => 'error',
  };

  /// The kept forecast of [p], unless it is older than [keepFor].
  WeatherForecast? cached(ProjectPoint p) {
    final f = WeatherForecast.fromJsonString(db.setting(_key(p)));
    if (f == null) return null;
    if (now().difference(f.fetchedAt) > keepFor) {
      db.setSetting(_key(p), null);
      return null;
    }
    return f;
  }

  /// Fetches the forecast of [p] and keeps it; the kept one when it is
  /// still fresh (unless [force]). Null when there is no connection and
  /// nothing kept. Never throws.
  Future<WeatherForecast?> refresh(ProjectPoint p, {bool force = false}) async {
    final kept = cached(p);
    if (!force && kept != null && now().difference(kept.fetchedAt) < freshFor) {
      return kept;
    }
    try {
      final client = await _client();
      final response = await client
          .get(
            Uri.parse(metUrl).replace(
              queryParameters: {
                'lat': p.lat.toStringAsFixed(4),
                'lon': p.lon.toStringAsFixed(4),
              },
            ),
            headers: {'User-Agent': userAgent},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode > 299) {
        lastError = 'HTTP ${response.statusCode}';
        return kept;
      }
      final hours = parseMetNorway(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
      if (hours.isEmpty) {
        lastError = 'empty forecast';
        return kept;
      }
      final forecast = WeatherForecast(
        fetchedAt: now(),
        hours: hours,
        kp: await _kp() ?? kept?.kp ?? const {},
      );
      db.setSetting(_key(p), forecast.toJsonString());
      lastError = null;
      return forecast;
    } catch (e) {
      lastError = describe(e);
      return kept;
    }
  }

  Future<Map<DateTime, double>?> _kp() async {
    try {
      final client = await _client();
      final response = await client
          .get(Uri.parse(kpUrl), headers: {'User-Agent': userAgent})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final kp = parseKpForecast(jsonDecode(response.body));
      return kp.isEmpty ? null : kp;
    } catch (_) {
      return null;
    }
  }

  bool _prefetching = false;

  /// Fetches the forecasts of all active projects, so they are on this
  /// device when the internet is gone. Called after every sync.
  Future<void> prefetch(Iterable<Project> projects) async {
    if (_prefetching) return;
    _prefetching = true;
    try {
      final seen = <String>{};
      for (final project in projects) {
        if (!project.active) continue;
        final p = weatherPoint(project);
        if (p == null || !seen.add(_key(p))) continue;
        await refresh(p);
      }
    } finally {
      _prefetching = false;
    }
  }
}
