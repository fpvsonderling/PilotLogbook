import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../local_db.dart';
import '../schema.dart';

/// Sends one JSON request to the spreadsheet's Apps Script and returns its
/// JSON answer. An interface so tests can run sync without the network.
abstract class SyncTransport {
  Future<Map<String, Object?>> call(Map<String, Object?> body);
}

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Talks to the Apps Script web app deployed from apps_script/Code.gs.
class AppsScriptTransport implements SyncTransport {
  AppsScriptTransport(this.url, {http.Client? client})
    : _client = client ?? http.Client();

  final String url;
  final http.Client _client;

  @override
  Future<Map<String, Object?>> call(Map<String, Object?> body) async {
    final request = http.Request('POST', Uri.parse(url))
      ..followRedirects = false
      ..headers['Content-Type'] = 'text/plain;charset=utf-8'
      ..body = jsonEncode(body);
    var response = await http.Response.fromStream(await _client.send(request));
    // Apps Script answers a POST with a redirect to the result, which must be
    // fetched with GET; the http package does not follow it for POST.
    final location = response.headers['location'];
    if (response.isRedirect && location != null) {
      response = await _client.get(Uri.parse(location));
    }
    if (response.statusCode != 200) {
      throw SyncException('HTTP ${response.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw SyncException(
        'The script did not answer with JSON. Check the web app URL and that '
        'it is deployed with access "Anyone".',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw SyncException('Unexpected answer from the script');
    }
    if (decoded['ok'] != true) {
      throw SyncException('${decoded['error'] ?? 'Sync failed'}');
    }
    return decoded;
  }
}

class SyncResult {
  const SyncResult({required this.pushed, required this.pulled});
  final int pushed;
  final int pulled;
}

/// One sync = upload every dirty row, then download every row the
/// spreadsheet changed since the last sync, in a single request.
class SyncService extends ChangeNotifier {
  SyncService(this.db);

  final LocalDb db;

  bool _running = false;
  bool get running => _running;
  String? lastError;
  DateTime? lastSyncedAt;

  static const urlKey = 'script_url';
  static const tokenKey = 'script_token';

  String? get url => db.setting(urlKey);
  String? get token => db.setting(tokenKey);
  bool get configured => (url ?? '').isNotEmpty && (token ?? '').isNotEmpty;

  /// The link connectionLink() prints in Apps Script: the web app URL with
  /// the access token as ?key=. Saves both; false when the link is not one.
  bool setConnectionLink(String link) {
    final uri = Uri.tryParse(link.trim());
    final key = uri?.queryParameters['key'] ?? '';
    if (uri == null || !uri.isScheme('https') || key.isEmpty) return false;
    db.setSetting(urlKey, link.trim().split('?').first);
    db.setSetting(tokenKey, key);
    notifyListeners();
    return true;
  }

  String get connectionLink => configured ? '$url?key=$token' : '';

  /// Builds the transport from settings; replaced in tests.
  SyncTransport Function(String url) transportFactory = AppsScriptTransport.new;

  int get pendingCount =>
      Tables.all.fold(0, (n, t) => n + db.dirtyRows(t).length);

  Future<SyncResult?> sync() async {
    if (_running || !configured) return null;
    _running = true;
    lastError = null;
    notifyListeners();
    try {
      final result = await _sync(transportFactory(url!));
      lastSyncedAt = DateTime.now();
      return result;
    } catch (e) {
      lastError = e.toString();
      return null;
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<SyncResult> _sync(SyncTransport transport) async {
    final push = <String, List<DbRow>>{};
    for (final t in Tables.all) {
      final rows = db.dirtyRows(t);
      if (rows.isNotEmpty) push[t.name] = rows;
    }
    final answer = await transport({
      'action': 'sync',
      'token': token,
      'push': push,
      'since': {for (final t in Tables.all) t.name: db.lastSeq(t)},
    });

    var pushed = 0;
    var pulled = 0;
    final accepted = (answer['accepted'] as Map?) ?? const {};
    final rows = (answer['pulled'] as Map?) ?? const {};
    final seqs = (answer['seq'] as Map?) ?? const {};
    db.transaction(() {
      for (final t in Tables.all) {
        for (final a in (accepted[t.name] as List?) ?? const []) {
          final m = a as Map;
          db.markSynced(
            t,
            m['id'] as String,
            m['updated_at'] as String,
            (m['server_seq'] as num).toInt(),
          );
          pushed++;
        }
        for (final r in (rows[t.name] as List?) ?? const []) {
          db.applyRemote(t, (r as Map).cast<String, Object?>());
          pulled++;
        }
        final seq = seqs[t.name];
        if (seq is num) db.setLastSeq(t, seq.toInt());
      }
    });
    return SyncResult(pushed: pushed, pulled: pulled);
  }
}
