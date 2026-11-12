import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/projects.dart';
import '../data/weather.dart';
import 'links.dart';
import 'theme.dart';

/// The forecast of the project's place in the flight form: now, the next
/// hours, and whether it is within the drone's limits. A preview only:
/// nothing here is saved with the flight.
class WeatherCard extends StatefulWidget {
  const WeatherCard({
    super.key,
    required this.service,
    required this.point,
    required this.place,
    required this.limits,
    this.droneName,
  });

  final WeatherService service;
  final ProjectPoint point;

  /// "Horns Rev 2 (T01)"
  final String place;
  final WeatherLimits limits;

  /// The drone picked in the form, named in the status line.
  final String? droneName;

  @override
  State<WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends State<WeatherCard> {
  WeatherForecast? _forecast;
  bool _loading = false;

  /// The last fetch failed: what is shown (if anything) is a kept forecast.
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _forecast = widget.service.cached(widget.point);
    _load();
  }

  @override
  void didUpdateWidget(WeatherCard old) {
    super.didUpdateWidget(old);
    if (old.point.lat != widget.point.lat ||
        old.point.lon != widget.point.lon) {
      _forecast = widget.service.cached(widget.point);
      _offline = false;
      _load();
    }
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _loading = true);
    final point = widget.point;
    final before = _forecast?.fetchedAt;
    final f = await widget.service.refresh(point, force: force);
    if (!mounted || point != widget.point) return;
    final fresh =
        f != null &&
        widget.service.now().difference(f.fetchedAt) < widget.service.freshFor;
    setState(() {
      _loading = false;
      _forecast = f;
      // Nothing new came, and what is kept is not from just now.
      _offline = f == null || (!fresh && f.fetchedAt == before);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = _forecast;
    final now = widget.service.now();
    final hour = f?.at(now);
    if (f == null || hour == null) {
      return Card(
        key: const Key('weather-card'),
        margin: const EdgeInsets.only(bottom: 16),
        child: ListTile(
          leading: Icon(Icons.cloud_off, color: scheme.onSurfaceVariant),
          title: Text(
            _loading
                ? 'Loading weather…'
                : 'No weather: ${widget.service.lastError ?? 'no connection'}',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          subtitle: Text(widget.place),
          trailing: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: 'Refresh',
                  onPressed: () => _load(force: true),
                  icon: const Icon(Icons.refresh),
                ),
        ),
      );
    }

    final c = CheckColors.of(context);
    final limits = widget.limits;
    final kp = f.kpAt(now);
    final problems = limits.problems(hour, kp);
    final ok = problems.isEmpty;
    Color level(double? v, double max) => v == null
        ? scheme.onSurface
        : v > max
        ? c.problem
        : v > max * 0.8
        ? AppPalette.gold
        : scheme.primary;
    final time = DateFormat('HH:mm').format(f.fetchedAt.toLocal());
    String n(double? v, [int digits = 1]) =>
        v == null ? '—' : v.toStringAsFixed(digits);
    final dir = hour.direction;

    return Card(
      key: const Key('weather-card'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.air, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Weather · ${widget.place}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _offline
                            ? 'Offline · forecast from $time'
                            : '${f.source} · updated $time',
                        style: TextStyle(
                          fontSize: 12,
                          color: _offline ? c.problem : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _loading
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Refresh',
                        onPressed: () => _load(force: true),
                        icon: const Icon(Icons.refresh),
                      ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: ok ? c.okContainer : c.problemContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      ok ? Icons.check_circle : Icons.warning_amber_rounded,
                      size: 18,
                      color: ok ? c.ok : c.problem,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        ok
                            ? widget.droneName == null
                                  ? 'Within limits'
                                  : 'Within limits for drone ${widget.droneName}'
                            : problems.join(' · '),
                        key: const Key('weather-status'),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: ok ? c.ok : c.problem,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: _Tile(
                      label: 'Wind m/s',
                      value: n(hour.wind),
                      sub: dir == null ? '' : 'from ${compass(dir)}',
                      color: level(hour.wind, limits.wind),
                      arrow: dir,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _Tile(
                      label: 'Gusts m/s',
                      value: hour.gustEstimated
                          ? '≈${n(hour.gustShown)}'
                          : n(hour.gustShown),
                      sub: hour.gustEstimated
                          ? 'est. · max ${WeatherLimits.fmt(limits.gust)}'
                          : 'max ${WeatherLimits.fmt(limits.gust)}',
                      color: level(hour.gustShown, limits.gust),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _Tile(
                      label: 'Rain mm',
                      value: n(hour.rain),
                      sub: hour.rainChance == null
                          ? ''
                          : '${hour.rainChance!.round()}%',
                      color: level(hour.rain, limits.rain),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _Tile(
                      label: 'Temp',
                      value: hour.temp == null ? '—' : '${hour.temp!.round()}°',
                      sub: '°C',
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              [
                if (hour.humidity != null)
                  'Humidity ${hour.humidity!.round()}%',
                if (hour.fog != null) 'Fog ${hour.fog!.round()}%',
                'Kp ${kp == null ? '—' : WeatherLimits.fmt(kp)}',
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Text(
              hour.gustEstimated
                  ? 'Next hours · wind / gusts m/s (≈ estimate, no gust forecast here)'
                  : 'Next hours · wind / gusts m/s',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                children: [
                  for (final h in f.next(now, 6))
                    Expanded(
                      child: _HourBar(
                        hour: h,
                        windColor: level(h.wind, limits.wind),
                        gustColor: level(
                          h.gustShown,
                          limits.gust,
                        ).withValues(alpha: 0.45),
                        rain: (h.rain ?? 0) > 0,
                      ),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Forecast only, not saved',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => openLink(context, windyUrl(widget.point)),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open in Windy'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
    this.arrow,
  });

  final String label;
  final String value;
  final String sub;
  final Color color;

  /// Wind from this direction (degrees): an arrow shows where it blows.
  final double? arrow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: small, maxLines: 1, overflow: TextOverflow.fade),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Row(
            children: [
              if (arrow != null)
                Transform.rotate(
                  angle: (arrow! + 180) * 3.141592653589793 / 180,
                  child: Icon(
                    Icons.arrow_upward,
                    size: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              Flexible(
                child: Text(
                  sub,
                  style: small,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HourBar extends StatelessWidget {
  const _HourBar({
    required this.hour,
    required this.windColor,
    required this.gustColor,
    required this.rain,
  });

  final WeatherHour hour;
  final Color windColor;
  final Color gustColor;
  final bool rain;

  Widget _bar(double? v, Color color) => Container(
    width: 8,
    height: ((v ?? 0) / 16 * 36).clamp(3, 36).toDouble(),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(2),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String r(double? v) => v == null ? '—' : v.round().toString();
    return Column(
      children: [
        Text(
          DateFormat('HH').format(hour.time.toLocal()),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 36,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _bar(hour.wind, windColor),
              const SizedBox(width: 2),
              _bar(hour.gustShown, gustColor),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '${r(hour.wind)}/${hour.gustEstimated ? '≈' : ''}${r(hour.gustShown)}',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
        rain
            ? Icon(
                Icons.water_drop,
                size: 12,
                color: CheckColors.of(context).problem,
              )
            : const SizedBox(height: 12),
      ],
    );
  }
}
