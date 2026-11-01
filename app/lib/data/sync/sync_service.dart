import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../local_db.dart';
import '../photos.dart';
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

  static const _redirects = {301, 302, 303, 307, 308};

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
    // isRedirect is false for a 302 answer to a POST, so check the status.
    if (_redirects.contains(response.statusCode) && location != null) {
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
  SyncService(this.db, {this.photos});

  final LocalDb db;

  /// Where fault photos are kept; without it photos are not uploaded.
  final PhotoStore? photos;

  bool _running = false;
  bool get running => _running;
  String? lastError;
  DateTime? lastSyncedAt;

  static const urlKey = 'script_url';
  static const tokenKey = 'script_token';
  static const adminKey = 'is_admin';

  String? get url => db.setting(urlKey);

  /// True when the link is the admin link: the script then accepts changes
  /// and deletes of every row, and the app shows those controls. Known after
  /// the first sync with the link.
  bool get isAdmin => db.setting(adminKey) == '1';

  /// People id when the link is a person's own link, else null.
  String? get me {
    final id = db.setting(LocalDb.meKey);
    return id == null || id.isEmpty ? null : id;
  }

  /// Whether this device may change or delete [row]: the admin any row,
  /// a person with their own link the rows they added.
  bool canChange(DbRow row) =>
      isAdmin || (me != null && row['created_by'] == me);

  /// The admin makes a person's own link, to send to them.
  Future<String> personLink(String personId) async {
    final answer = await transportFactory(url!)({
      'action': 'personLink',
      'token': token,
      'person_id': personId,
    });
    return '$url?key=${answer['token']}';
  }

  String? get token => db.setting(tokenKey);
  bool get configured => (url ?? '').isNotEmpty && (token ?? '').isNotEmpty;

  /// The link connectionLink() prints in Apps Script: the web app URL with
  /// the access token as ?key=. Saves both; false when the link is not one.
  bool setConnectionLink(String link) {
    final uri = Uri.tryParse(link.trim());
    final key = uri?.queryParameters['key'] ?? '';
    if (uri == null || !uri.isScheme('https') || key.isEmpty) return false;
    // The /dev URL only works for the script owner; the deployment is /exec.
    final url = link
        .trim()
        .split('?')
        .first
        .replaceFirst(RegExp(r'/dev$'), '/exec');
    db.setSetting(urlKey, url);
    if (key != token) {
      db.setSetting(adminKey, null);
      db.setSetting(LocalDb.meKey, null);
    }
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
    final waiting = await _uploadPhotos(transport);
    final push = <String, List<DbRow>>{};
    for (final t in Tables.all) {
      final rows = [
        for (final r in db.dirtyRows(t))
          if (!(t == Tables.faultPhotos && waiting.contains(r['id']))) r,
      ];
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
    final denied = (answer['denied'] as Map?) ?? const {};
    db.transaction(() {
      db.setSetting(adminKey, answer['admin'] == true ? '1' : '0');
      final me = answer['me'];
      db.setSetting(LocalDb.meKey, me is String && me.isNotEmpty ? me : null);
      for (final t in Tables.all) {
        // Edits the script refused (not the admin link): drop them, the
        // spreadsheet's version comes back in pulled.
        for (final id in (denied[t.name] as List?) ?? const []) {
          db.dropLocalChange(t, id as String);
        }
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

  /// Sends photos taken on this device to Drive and notes their file id, so
  /// the row reaches the sheet with it. Returns the ids of photos that
  /// could not be sent; their rows wait for the next sync.
  Future<Set<String>> _uploadPhotos(SyncTransport transport) async {
    final store = photos;
    if (store == null) return const {};
    final failed = <String>{};
    for (final r in store.pendingUploads(db)) {
      final id = r['id'] as String;
      try {
        final answer = await transport({
          'action': 'uploadPhoto',
          'token': token,
          'name': 'fault-${r['fault_id']}-$id.jpg',
          'mimeType': 'image/jpeg',
          'data': base64Encode(store.file(id).readAsBytesSync()),
        });
        db.save(Tables.faultPhotos, {
          'id': id,
          'drive_file_id': answer['drive_file_id'],
          'url': answer['url'],
        });
      } catch (e) {
        failed.add(id);
        lastError = 'Photo not sent: $e';
      }
    }
    return failed;
  }

  /// The picture of a fault_photos row: the local file, downloaded from
  /// Drive first when it was taken on another device. Null when it cannot
  /// be had now (offline, or not uploaded yet).
  Future<File?> photoFile(DbRow row) async {
    final store = photos;
    if (store == null) return null;
    final f = store.file(row['id'] as String);
    if (f.existsSync()) return f;
    final driveId = row['drive_file_id'] as String? ?? '';
    if (driveId.isEmpty || !configured) return null;
    try {
      final answer = await transportFactory(url!)({
        'action': 'photo',
        'token': token,
        'drive_file_id': driveId,
      });
      f.parent.createSync(recursive: true);
      await f.writeAsBytes(base64Decode(answer['data'] as String));
      return f;
    } catch (_) {
      return null;
    }
  }
}
