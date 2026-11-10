import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The newest published release of the app, as GitHub reports it.
class AppRelease {
  const AppRelease({
    required this.version,
    this.build,
    required this.pageUrl,
    this.downloads = const {},
  });

  /// "1.8.0" (the tag without its "v").
  final String version;

  /// CI run number the release was built in (the "+42" of APP_VERSION),
  /// when the release notes carry it.
  final int? build;

  /// The release page on GitHub.
  final String pageUrl;

  /// Asset file name -> direct download link.
  final Map<String, String> downloads;

  /// Marker the CI release job writes into the release notes.
  static final _buildMarker = RegExp(r'pilotlogbook-build:\s*(\d+)');

  /// Reads the answer of GET /repos/{owner}/{repo}/releases/latest.
  static AppRelease? fromGitHub(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final body = json['body'];
    final build = body is String ? _buildMarker.firstMatch(body) : null;
    return AppRelease(
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      build: build == null ? null : int.parse(build.group(1)!),
      pageUrl: json['html_url'] as String? ?? UpdateChecker.releasesPage,
      downloads: {
        for (final asset in (json['assets'] as List? ?? const []))
          if (asset is Map &&
              asset['name'] is String &&
              asset['browser_download_url'] is String)
            asset['name'] as String: asset['browser_download_url'] as String,
      },
    );
  }

  /// Where a person on [platform] ("windows", "android", "macos", "ios")
  /// gets this version: the file for their system, TestFlight on an
  /// iPhone, the release page otherwise.
  String downloadUrl(String platform) {
    if (platform == 'ios') return UpdateChecker.testFlight;
    final ending = switch (platform) {
      'android' => '.apk',
      _ => '.zip',
    };
    for (final MapEntry(key: name, value: url) in downloads.entries) {
      final lower = name.toLowerCase();
      if (lower.contains(platform) && lower.endsWith(ending)) return url;
    }
    return pageUrl;
  }
}

/// "1.7.0+123" -> (name 1.7.0, build 123). "dev build" -> null.
({List<int> name, int? build})? parseAppVersion(String version) {
  final match = RegExp(r'^v?(\d+(?:\.\d+)*)(?:\+(\d+))?$')
      .firstMatch(version.trim());
  if (match == null) return null;
  return (
    name: match.group(1)!.split('.').map(int.parse).toList(),
    build: match.group(2) == null ? null : int.parse(match.group(2)!),
  );
}

int _compareNames(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// True when the app built as [current] is older than [latest].
///
/// Every CI build has a build number that only grows (the run number), so
/// that decides when both sides have one: a TestFlight build made after the
/// release counts as up to date even though its version name is older. A
/// copy run from source ("dev build") is never reported as old.
bool isOutdated(String current, AppRelease latest) {
  final mine = parseAppVersion(current);
  if (mine == null) return false;
  if (mine.build != null && latest.build != null) {
    return mine.build! < latest.build!;
  }
  final theirs = parseAppVersion(latest.version);
  if (theirs == null) return false;
  return _compareNames(mine.name, theirs.name) < 0;
}

/// The system this copy runs on, as used in the release file names.
String currentPlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  return 'other';
}

/// Asks GitHub for the newest release now and then, and tells the app when
/// this copy is older, so people know to install the new one.
///
/// Without internet (or when GitHub does not answer) nothing is shown: the
/// app keeps working offline as before.
class UpdateChecker extends ChangeNotifier {
  UpdateChecker({
    required this.current,
    http.Client? client,
    String? platform,
    this.minInterval = const Duration(hours: 1),
  }) : _client = client ?? http.Client(),
       platform = platform ?? currentPlatform();

  static const latestApi =
      'https://api.github.com/repos/fpvsonderling/PilotLogbook/releases/latest';
  static const releasesPage =
      'https://github.com/fpvsonderling/PilotLogbook/releases/latest';

  /// Opens the TestFlight app, where the new iPhone / iPad build waits.
  static const testFlight = 'itms-beta://';

  /// APP_VERSION of this copy, such as "1.7.0+123".
  final String current;

  /// "windows", "android", "ios", "macos" or "other".
  final String platform;

  /// Checks closer together than this are skipped (the app checks again
  /// every time it comes back to the front).
  final Duration minInterval;

  final http.Client _client;
  DateTime? _lastCheck;
  bool _checking = false;

  /// Set once GitHub reports a release newer than this copy.
  AppRelease? get newer => _newer;
  AppRelease? _newer;

  /// Where to get the new version on this system.
  String? get downloadUrl => _newer?.downloadUrl(platform);

  /// Asks GitHub; [force] ignores [minInterval]. Never throws. True when
  /// GitHub answered (or was asked recently).
  Future<bool> check({bool force = false}) async {
    if (_checking || parseAppVersion(current) == null) return false;
    final now = DateTime.now();
    if (!force &&
        _lastCheck != null &&
        now.difference(_lastCheck!) < minInterval) {
      return true;
    }
    _checking = true;
    try {
      final response = await _client
          .get(
            Uri.parse(latestApi),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return false;
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return false;
      final release = AppRelease.fromGitHub(json);
      if (release == null) return false;
      _lastCheck = now;
      final newer = isOutdated(current, release) ? release : null;
      if (newer?.version != _newer?.version || newer?.build != _newer?.build) {
        _newer = newer;
        notifyListeners();
      }
      return true;
    } catch (_) {
      // Offline or GitHub unreachable: try again next time.
      return false;
    } finally {
      _checking = false;
    }
  }
}
