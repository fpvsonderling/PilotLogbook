import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/projects.dart';
import 'package:pilot_logbook/data/schema.dart';
import 'package:pilot_logbook/data/weather.dart';
import 'package:pilot_logbook/main.dart';

/// A MET Norway answer: [hourly] hours from [start], then two 6-hour steps.
Map<String, dynamic> metAnswer(
  DateTime start, {
  int hourly = 8,
  double wind = 6.4,
  double? gust = 9.1,
  double rain = 0,
}) {
  Map<String, dynamic> step(DateTime t, int i) => {
    'time': t.toIso8601String(),
    'data': {
      'instant': {
        'details': {
          'wind_speed': wind + i * 0.5,
          if (gust != null) 'wind_speed_of_gust': gust + i * 0.5,
          'wind_from_direction': 225.0,
          'air_temperature': 7.2,
          'relative_humidity': 81.0,
          'fog_area_fraction': 0.0,
        },
      },
      'next_1_hours': {
        'details': {
          'precipitation_amount': rain,
          'probability_of_precipitation': 10.0,
        },
      },
    },
  };
  final last = start.add(Duration(hours: hourly - 1));
  return {
    'properties': {
      'timeseries': [
        for (var i = 0; i < hourly; i++) step(start.add(Duration(hours: i)), i),
        step(last.add(const Duration(hours: 6)), 0),
        step(last.add(const Duration(hours: 12)), 0),
      ],
    },
  };
}

DateTime thisHour() {
  final n = DateTime.now().toUtc();
  return DateTime.utc(n.year, n.month, n.day, n.hour);
}

const kpAnswer = [
  ['time_tag', 'kp', 'observed', 'noaa_scale'],
];

List<List<Object?>> kpRows(DateTime start, double kp) => [
  ...kpAnswer,
  for (var i = -1; i < 4; i++)
    [
      start
          .add(Duration(hours: 3 * i))
          .toIso8601String()
          .replaceFirst('T', ' ')
          .replaceFirst('.000Z', ''),
      '$kp',
      'predicted',
      null,
    ],
];

void main() {
  test('MET Norway answer is read hour by hour, 6-hour steps left out', () {
    final start = DateTime.utc(2026, 11, 12, 13);
    final hours = parseMetNorway(metAnswer(start));
    expect(hours, hasLength(8));
    expect(hours.first.time, start);
    expect(hours.first.wind, 6.4);
    expect(hours.first.gust, 9.1);
    expect(hours.first.direction, 225);
    expect(hours.first.temp, 7.2);
    expect(hours.first.rain, 0);
    expect(hours.first.rainChance, 10);
    expect(compass(225), 'SW');
    expect(compass(359), 'N');
  });

  test('Kp forecast is read in both NOAA formats', () {
    final rows = parseKpForecast([
      ['time_tag', 'kp', 'observed', 'noaa_scale'],
      ['2026-11-12 12:00:00', '2.33', 'observed', null],
      ['2026-11-12 15:00:00', '5.67', 'predicted', 'G1'],
    ]);
    expect(rows[DateTime.utc(2026, 11, 12, 15)], 5.67);
    final objects = parseKpForecast([
      {'time_tag': '2026-11-12T12:00:00', 'kp': 3},
    ]);
    expect(objects[DateTime.utc(2026, 11, 12, 12)], 3);

    final f = WeatherForecast(
      fetchedAt: DateTime.utc(2026, 11, 12, 12),
      hours: const [],
      kp: rows,
    );
    expect(f.kpAt(DateTime.utc(2026, 11, 12, 14, 59)), 2.33);
    expect(f.kpAt(DateTime.utc(2026, 11, 12, 16)), 5.67);
  });

  test('limits come from the drone, else the defaults', () {
    expect(WeatherLimits.of(null).wind, 10);
    expect(WeatherLimits.of(null).gust, 12);
    final l = WeatherLimits.of({'max_wind_ms': '8', 'max_gust_ms': '10,5'});
    expect(l.wind, 8);
    expect(l.gust, 10.5);
    final h = WeatherHour(
      time: DateTime.utc(2026),
      wind: 9,
      gust: 11,
      rain: 0.8,
    );
    expect(l.problems(h, 5), [
      'Wind above 8 m/s',
      'Gusts above 10.5 m/s',
      'Rain',
      'Kp 5: GPS may be poor',
    ]);
    expect(const WeatherLimits().problems(h, 2), ['Rain']);
  });

  test('without a gust forecast, gusts are estimated from the wind', () {
    final h = parseMetNorway(metAnswer(DateTime.utc(2026), gust: null)).first;
    expect(h.gust, isNull);
    expect(h.gustEstimated, isTrue);
    expect(h.gustShown, closeTo(6.4 * 1.4, 1e-9));
    final windy = WeatherHour(time: DateTime.utc(2026), wind: 9.2);
    expect(const WeatherLimits().problems(windy, null), [
      'Gusts (est.) above 12 m/s',
    ]);
    final known = WeatherHour(time: DateTime.utc(2026), wind: 9.2, gust: 10);
    expect(known.gustEstimated, isFalse);
    expect(known.gustShown, 10);
    expect(WeatherHour(time: DateTime.utc(2026)).gustShown, isNull);
  });

  test('the card says why the fetch failed', () {
    expect(
      WeatherService.describe(const HandshakeException('CERTIFICATE')),
      'certificate error',
    );
    expect(
      WeatherService.describe(
        http.ClientException('HandshakeException: CERTIFICATE_VERIFY_FAILED'),
      ),
      'certificate error',
    );
    expect(WeatherService.describe(TimeoutException('slow')), 'timeout');
    expect(
      WeatherService.describe(const SocketException('down')),
      'no connection',
    );
  });

  test('project place: first point, else its maps link', () {
    expect(
      weatherPoint(Project({'coordinates': 'T01: 55.6, 7.6\nT02: 55.7, 7.7'})),
      const ProjectPoint(55.6, 7.6, 'T01'),
    );
    expect(
      weatherPoint(
        Project({'maps_url': 'https://www.google.com/maps/@54.9,18.1,12z'}),
      ),
      const ProjectPoint(54.9, 18.1),
    );
    expect(weatherPoint(Project({'name': 'x'})), isNull);
    expect(
      windyUrl(const ProjectPoint(55.6, 7.6)),
      'https://www.windy.com/55.6000/7.6000?55.6000,7.6000,11',
    );
  });

  group('WeatherService', () {
    const p = ProjectPoint(55.6, 7.6);
    late DateTime now;
    late int metCalls;
    late bool online;

    WeatherService service(LocalDb db) => WeatherService(
      db,
      clock: () => now,
      client: MockClient((request) async {
        if (!online) throw http.ClientException('offline');
        if (request.url.host == 'api.met.no') {
          metCalls++;
          expect(request.headers['User-Agent'], contains('PilotLogbook'));
          expect(request.url.queryParameters['lat'], '55.6000');
          return http.Response(jsonEncode(metAnswer(thisHour())), 200);
        }
        return http.Response(jsonEncode(kpRows(thisHour(), 2)), 200);
      }),
    );

    setUp(() {
      now = DateTime.now();
      metCalls = 0;
      online = true;
    });

    test('keeps the forecast, fetches again only when it is old', () async {
      final db = LocalDb.inMemory();
      final s = service(db);
      final f = await s.refresh(p);
      expect(f!.hours, hasLength(8));
      expect(f.kpAt(now), 2);
      expect(metCalls, 1);

      await s.refresh(p);
      expect(metCalls, 1, reason: 'still fresh');
      await s.refresh(p, force: true);
      expect(metCalls, 2);

      // Offline: the kept one comes back.
      online = false;
      now = now.add(const Duration(hours: 2));
      final kept = await s.refresh(p);
      expect(kept!.hours, hasLength(8));
      expect(service(db).cached(p), isNotNull, reason: 'kept on the device');

      // After 48 hours it is gone.
      now = now.add(const Duration(hours: 47));
      expect(await s.refresh(p), isNull);
      expect(s.cached(p), isNull);
    });

    test('prefetch fetches every active project once', () async {
      final db = LocalDb.inMemory();
      await service(db).prefetch([
        Project({'active': 1, 'coordinates': '55.6, 7.6'}),
        Project({'active': 1, 'coordinates': '55.6, 7.6\n55.7, 7.7'}),
        Project({'active': 0, 'coordinates': '54, 18'}),
        Project({'active': 1}),
      ]);
      expect(metCalls, 1);
    });
  });

  group('flight form', () {
    Future<LocalDb> open(
      WidgetTester tester, {
      bool online = true,
      double? gust = 9.1,
      int status = 200,
      String? coordinates = 'T01: 55.6, 7.6',
    }) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      final db = LocalDb.inMemory();
      db.save(Tables.projects, {
        'name': 'Horns Rev 2',
        'active': 1,
        'coordinates': coordinates,
      });
      db.save(Tables.aircraft, {
        'name': '19',
        'active': 1,
        'max_gust_ms': '12',
      });
      final weather = WeatherService(
        db,
        client: MockClient((request) async {
          if (!online) throw http.ClientException('offline');
          return request.url.host == 'api.met.no'
              ? http.Response(
                  jsonEncode(metAnswer(thisHour(), gust: gust)),
                  status,
                )
              : http.Response(jsonEncode(kpRows(thisHour(), 2)), 200);
        }),
      );
      await tester.pumpWidget(PilotLogbookApp(db: db, weather: weather));
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Horns Rev 2'));
      await tester.pumpAndSettle();
      return db;
    }

    testWidgets('shows the weather of the project, within limits', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Weather · Horns Rev 2 (T01)'), findsOneWidget);
      expect(find.text('Within limits'), findsOneWidget);
      expect(find.text('Open in Windy'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '19'));
      await tester.pumpAndSettle();
      expect(find.text('Within limits for drone 19'), findsOneWidget);
    });

    testWidgets('warns about gusts above the drone limit', (tester) async {
      await open(tester, gust: 14.6);
      await tester.tap(find.widgetWithText(ChoiceChip, '19'));
      await tester.pumpAndSettle();
      expect(find.text('Gusts above 12 m/s'), findsOneWidget);
    });

    testWidgets('no connection and nothing kept', (tester) async {
      await open(tester, online: false);
      expect(find.text('No weather: no connection'), findsOneWidget);
    });

    testWidgets('a refused request says so', (tester) async {
      await open(tester, status: 403);
      expect(find.text('No weather: HTTP 403'), findsOneWidget);
    });

    testWidgets('outside the Nordics gusts are an estimate', (tester) async {
      await open(tester, gust: null);
      expect(find.text('≈9.0'), findsOneWidget);
      expect(find.text('est. · max 12'), findsOneWidget);
      expect(find.text('6/≈9'), findsOneWidget);
    });

    testWidgets('no card for a project without coordinates', (tester) async {
      await open(tester, coordinates: null);
      expect(find.byKey(const Key('weather-card')), findsNothing);
    });

    testWidgets('nothing about the weather is saved with the flight', (
      tester,
    ) async {
      final db = await open(tester);
      expect(find.byKey(const Key('weather-card')), findsOneWidget);
      expect(
        Tables.flights.columns.where((c) => c.name.contains('wind')),
        isEmpty,
      );
      expect(db.rows(Tables.flights), isEmpty);
    });
  });
}
