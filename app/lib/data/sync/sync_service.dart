import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../documents.dart';
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
  SyncService(this.db, {this.photos, this.documents});

  final LocalDb db;

  /// Where fault photos are kept; without it photos are not uploaded.
  final PhotoStore? photos;

  /// Where offline copies of documents are kept; without it documents are
  /// not downloaded.
  final DocumentStore? documents;

  bool _running = false;
  bool get running => _running;
  String? lastError;
  DateTime? lastSyncedAt;

  static const urlKey = 'script_url';
  static const tokenKey = 'script_token';
  static const adminKey = 'is_admin';

  /// '0' when this device downloads documents only when they are opened;
  /// otherwise every document is downloaded after each sync.
  static const documentsOfflineKey = 'documents_offline';

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
      _afterSync();
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

  // ------------------------------------------------------------ documents

  /// Download progress (0..1) of documents being fetched now, by row id.
  final downloads = <String, double>{};

  /// Why the last download of a document failed, by row id.
  final downloadErrors = <String, String>{};

  bool get keepDocumentsOffline => db.setting(documentsOfflineKey) != '0';

  set keepDocumentsOffline(bool value) {
    db.setSetting(documentsOfflineKey, value ? '1' : '0');
    notifyListeners();
    if (value) downloadAllDocuments();
  }

  /// Sends a file to Drive the way the admin's app does: the script starts
  /// the upload and gives an address, the file goes straight there, and
  /// Drive answers with the new file. Replaced in tests.
  Future<Map<String, Object?>> Function(
    String uploadUrl,
    File file,
    String mime,
  )
  uploader = _put;

  static Future<Map<String, Object?>> _put(
    String uploadUrl,
    File file,
    String mime,
  ) async {
    final request = http.StreamedRequest('PUT', Uri.parse(uploadUrl))
      ..headers['Content-Type'] = mime
      ..contentLength = await file.length();
    file.openRead().listen(
      request.sink.add,
      onDone: request.sink.close,
      onError: request.sink.addError,
    );
    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw SyncException('Drive upload failed: HTTP ${response.statusCode}');
    }
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  /// Uploads [file] to the documents folder in Drive (admin link only) and
  /// returns the columns to save in its documents row.
  Future<Map<String, Object?>> uploadDocument(File file) async {
    if (!configured) throw SyncException('Sync is not set up');
    final name = file.uri.pathSegments.last;
    final mime = mimeTypeOf(name);
    final transport = transportFactory(url!);
    final start = await transport({
      'action': 'documentUpload',
      'token': token,
      'name': name,
      'mimeType': mime,
      'size': await file.length(),
    });
    final created = await uploader(start['upload_url'] as String, file, mime);
    return documentInfo(created['id'] as String);
  }

  /// Name, type, size and version of a Drive file the admin links.
  Future<Map<String, Object?>> documentInfo(String driveFileId) async {
    if (!configured) throw SyncException('Sync is not set up');
    final info = await transportFactory(url!)({
      'action': 'documentInfo',
      'token': token,
      'drive_file_id': driveFileId,
    });
    return {
      'drive_file_id': info['drive_file_id'],
      'file_name': info['file_name'],
      'mime_type': info['mime_type'],
      'size_bytes': int.tryParse('${info['size_bytes'] ?? ''}'),
      'file_version': info['file_version'],
      'url': info['url'],
    };
  }

  /// The document's file on this device, downloaded first when there is no
  /// copy of its current version. Offline, an older copy is better than
  /// none. Null when there is no file to be had now.
  Future<File?> documentFile(DbRow row) async {
    final store = documents;
    if (store == null) return null;
    final have = store.cached(row);
    if (have != null) return have;
    final got = await _download(row);
    if (got != null) return got;
    final old = store.folder(row['id'] as String);
    if (!old.existsSync()) return null;
    for (final f in old.listSync().whereType<File>()) {
      if (!f.uri.pathSegments.last.startsWith('.')) return f;
    }
    return null;
  }

  /// Downloads every document this device has no current copy of.
  Future<void> downloadAllDocuments() async {
    final store = documents;
    if (store == null) return;
    for (final row in db.rows(Tables.documents)) {
      if ((row['drive_file_id'] as String? ?? '').isEmpty) continue;
      if (store.cached(row) == null) await _download(row);
    }
  }

  void _afterSync() {
    final store = documents;
    if (store == null) return;
    try {
      store.prune([
        for (final r in db.rows(Tables.documents)) r['id'] as String,
      ]);
    } catch (_) {
      // A file kept open by another program; tried again next sync.
    }
    if (keepDocumentsOffline) downloadAllDocuments();
  }

  Future<File?> _download(DbRow row) async {
    final store = documents;
    final id = row['id'] as String;
    final driveId = row['drive_file_id'] as String? ?? '';
    if (store == null || driveId.isEmpty || !configured) return null;
    if (downloads.containsKey(id)) return null;
    downloads[id] = 0;
    downloadErrors.remove(id);
    notifyListeners();
    final part = store.partFile(row);
    IOSink? sink;
    try {
      part.parent.createSync(recursive: true);
      sink = part.openWrite();
      final transport = transportFactory(url!);
      var offset = 0;
      while (true) {
        final answer = await transport({
          'action': 'documentPart',
          'token': token,
          'drive_file_id': driveId,
          'offset': offset,
        });
        final bytes = base64Decode(answer['data'] as String? ?? '');
        final size = (answer['size'] as num?)?.toInt() ?? 0;
        sink.add(bytes);
        offset += bytes.length;
        downloads[id] = size > 0 ? offset / size : 1;
        notifyListeners();
        if (bytes.isEmpty || offset >= size) break;
      }
      await sink.close();
      sink = null;
      return store.finish(row);
    } catch (e) {
      downloadErrors[id] = e.toString();
      await sink?.close();
      if (part.existsSync()) part.deleteSync();
      return null;
    } finally {
      downloads.remove(id);
      notifyListeners();
    }
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
