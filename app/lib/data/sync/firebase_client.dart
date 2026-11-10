import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'sync_errors.dart';

/// A Firebase access key: which Firebase project, and the Firebase Auth
/// account (email + password) the key stands for. People paste it in
/// Settings as "PL2-" and base64url of "project apiKey id secret".
class FirebaseKey {
  const FirebaseKey({
    required this.projectId,
    required this.apiKey,
    required this.id,
    required this.secret,
  });

  final String projectId;
  final String apiKey;

  /// Account id and password; the account's email is made from the id.
  final String id;
  final String secret;

  static const prefix = 'PL2-';

  /// Firebase Auth wants an email; nothing is ever sent to it.
  String get email => emailOf(id);

  static String emailOf(String id) => 'key-$id@pilotlogbook.app';

  String encode() =>
      prefix +
      base64Url
          .encode(utf8.encode('$projectId $apiKey $id $secret'))
          .replaceAll('=', '');

  static FirebaseKey? decode(String text) {
    final t = text.trim();
    if (!t.startsWith(prefix)) return null;
    final String payload;
    try {
      payload = utf8.decode(
        base64Url.decode(base64Url.normalize(t.substring(prefix.length))),
      );
    } on FormatException {
      return null;
    }
    final parts = payload.split(' ');
    if (parts.length != 4 || parts.any((p) => p.isEmpty)) return null;
    return FirebaseKey(
      projectId: parts[0],
      apiKey: parts[1],
      id: parts[2],
      secret: parts[3],
    );
  }

  /// A new random key in the same project, for a new account.
  FirebaseKey fresh() => FirebaseKey(
    projectId: projectId,
    apiKey: apiKey,
    id: _random(12),
    secret: _random(24),
  );

  static String _random(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final r = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        chars.codeUnitAt(r.nextInt(chars.length)),
    ]);
  }
}

/// Where the Firebase services are: Google's servers, or the local
/// emulators in tests.
class FirebaseHosts {
  const FirebaseHosts({
    this.auth = 'https://identitytoolkit.googleapis.com',
    this.firestore = 'https://firestore.googleapis.com',
    this.storage = 'https://firebasestorage.googleapis.com',
  });

  /// The Firebase emulators on this computer (firebase emulators:start).
  const FirebaseHosts.emulator([String host = '127.0.0.1'])
    : auth = 'http://$host:9099/identitytoolkit.googleapis.com',
      firestore = 'http://$host:8080',
      storage = 'http://$host:9199';

  final String auth;
  final String firestore;
  final String storage;
}

/// The caller is not allowed to do this (security rules).
class PermissionDenied extends SyncException {
  PermissionDenied(super.message);
}

/// Cloud Firestore, Firebase Auth and Cloud Storage over their REST APIs,
/// so the app works the same on Windows, macOS, Android and iOS and keeps
/// its own offline database (no Firebase SDK cache).
class FirebaseClient {
  FirebaseClient(
    this.key, {
    http.Client? client,
    this.hosts = const FirebaseHosts(),
  }) : _http = client ?? http.Client();

  final FirebaseKey key;
  final FirebaseHosts hosts;
  final http.Client _http;

  String? _idToken;
  String? _uid;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  String get _db => 'projects/${key.projectId}/databases/(default)/documents';

  /// The Firebase Auth user id of this key; known after [signIn].
  String get uid => _uid!;

  // ------------------------------------------------------------------ auth

  /// Signs in with the key's account, unless still signed in.
  Future<String> signIn() async {
    if (_idToken != null && DateTime.now().isBefore(_expires)) {
      return _idToken!;
    }
    final answer = await _auth('accounts:signInWithPassword', {
      'email': key.email,
      'password': key.secret,
      'returnSecureToken': true,
    });
    _idToken = answer['idToken'] as String;
    _uid = answer['localId'] as String;
    final seconds = int.tryParse('${answer['expiresIn']}') ?? 3600;
    _expires = DateTime.now().add(Duration(seconds: seconds - 120));
    return _idToken!;
  }

  /// Makes the Firebase Auth account of a new key and returns its user id.
  /// This client stays signed in as itself.
  Future<String> createAccount(FirebaseKey newKey) async {
    final answer = await _auth('accounts:signUp', {
      'email': newKey.email,
      'password': newKey.secret,
      'returnSecureToken': true,
    });
    return answer['localId'] as String;
  }

  Future<Map<String, Object?>> _auth(String method, Map body) async {
    final http.Response res;
    try {
      res = await _http.post(
        Uri.parse('${hosts.auth}/v1/$method?key=${key.apiKey}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
    } on SocketException {
      throw SyncException('No connection to the server');
    }
    final decoded = _json(res.body);
    if (res.statusCode != 200) {
      final message = '${(decoded['error'] as Map?)?['message'] ?? ''}';
      if (message.contains('INVALID_LOGIN_CREDENTIALS') ||
          message.contains('INVALID_PASSWORD') ||
          message.contains('EMAIL_NOT_FOUND') ||
          message.contains('USER_DISABLED')) {
        throw SyncException(
          'Access key not valid or turned off. Ask the administrator.',
        );
      }
      throw SyncException(
        'Sign in failed: ${message.isEmpty ? res.statusCode : message}',
      );
    }
    return decoded;
  }

  // ------------------------------------------------------------- firestore

  Future<Map<String, String>> _headers() async => {
    'Authorization': 'Bearer ${await signIn()}',
    'Content-Type': 'application/json',
  };

  /// The document at [path] (e.g. "flights/abc") as plain values, null when
  /// there is none.
  Future<Map<String, Object?>?> get(String path) async {
    final res = await _send(
      () async => _http.get(
        Uri.parse('${hosts.firestore}/v1/$_db/$path'),
        headers: await _headers(),
      ),
      allow404: true,
    );
    if (res == null) return null;
    return decodeFields(_json(res.body)['fields'] as Map? ?? const {});
  }

  /// Writes all [writes] (made with [upsert] and [stamp]) at once: all or
  /// nothing. Returns the server time the writes got.
  Future<DateTime> commit(List<Map<String, Object?>> writes) async {
    final res = await _send(
      () async => _http.post(
        Uri.parse('${hosts.firestore}/v1/$_db:commit'),
        headers: await _headers(),
        body: jsonEncode({'writes': writes}),
      ),
    );
    final answer = _json(res!.body);
    return DateTime.parse(answer['commitTime'] as String);
  }

  /// A write that replaces document [path] with [fields] and sets field
  /// [stampField] to the server's time.
  Map<String, Object?> upsert(
    String path,
    Map<String, Object?> fields, {
    String stampField = 'server_time',
  }) => {
    'update': {'name': '$_db/$path', 'fields': encodeFields(fields)},
    'updateTransforms': [
      {'fieldPath': stampField, 'setToServerValue': 'REQUEST_TIME'},
    ],
  };

  /// A write that only sets [fieldNames] of document [path] to the
  /// server's time, keeping its other fields.
  Map<String, Object?> stamp(String path, Iterable<String> fieldNames) => {
    'update': {'name': '$_db/$path', 'fields': const {}},
    'updateMask': {'fieldPaths': const []},
    'updateTransforms': [
      for (final f in fieldNames)
        {'fieldPath': _fieldPath(f), 'setToServerValue': 'REQUEST_TIME'},
    ],
  };

  /// Documents of [collection], in order of server_time, changed after
  /// [after] (all when null); or, with [equals], those whose field has that
  /// value. Read page by page.
  Future<List<Map<String, Object?>>> query(
    String collection, {
    DateTime? after,
    MapEntry<String, String>? equals,
    int pageSize = 500,
  }) async {
    final out = <Map<String, Object?>>[];
    Object? cursor;
    while (true) {
      final q = <String, Object?>{
        'from': [
          {'collectionId': collection},
        ],
        if (equals != null)
          'where': {
            'fieldFilter': {
              'field': {'fieldPath': equals.key},
              'op': 'EQUAL',
              'value': {'stringValue': equals.value},
            },
          }
        else if (after != null)
          'where': {
            'fieldFilter': {
              'field': {'fieldPath': 'server_time'},
              'op': 'GREATER_THAN',
              'value': {'timestampValue': _timestamp(after)},
            },
          },
        if (equals == null) ...{
          'orderBy': [
            {
              'field': {'fieldPath': 'server_time'},
              'direction': 'ASCENDING',
            },
            {
              'field': {'fieldPath': '__name__'},
              'direction': 'ASCENDING',
            },
          ],
          'limit': pageSize,
          if (cursor != null) 'startAt': {'values': cursor, 'before': false},
        },
      };
      final res = await _send(
        () async => _http.post(
          Uri.parse('${hosts.firestore}/v1/$_db:runQuery'),
          headers: await _headers(),
          body: jsonEncode({'structuredQuery': q}),
        ),
      );
      final results = jsonDecode(res!.body) as List;
      var count = 0;
      Map? last;
      for (final r in results) {
        final d = (r as Map)['document'] as Map?;
        if (d == null) continue;
        count++;
        last = d;
        out.add(decodeFields(d['fields'] as Map? ?? const {}));
      }
      if (equals != null || count < pageSize || last == null) return out;
      cursor = [
        (last['fields'] as Map)['server_time'],
        {'referenceValue': last['name']},
      ];
    }
  }

  // --------------------------------------------------------------- storage

  String _object(String bucket, String path) =>
      '${hosts.storage}/v0/b/$bucket/o/${Uri.encodeComponent(path)}';

  /// Uploads [file] to Cloud Storage at [path].
  Future<void> upload(
    String bucket,
    String path,
    File file,
    String mime,
  ) async {
    final request =
        http.StreamedRequest(
            'POST',
            Uri.parse(
              '${hosts.storage}/v0/b/$bucket/o?name=${Uri.encodeQueryComponent(path)}',
            ),
          )
          ..headers['Authorization'] = 'Firebase ${await signIn()}'
          ..headers['Content-Type'] = mime
          ..contentLength = await file.length();
    file.openRead().listen(
      request.sink.add,
      onDone: request.sink.close,
      onError: request.sink.addError,
    );
    final res = await http.Response.fromStream(await _http.send(request));
    _check(res);
  }

  /// Downloads the file at [path] into [into], reporting progress (0..1).
  Future<void> download(
    String bucket,
    String path,
    File into, {
    void Function(double)? progress,
  }) async {
    final request = http.Request(
      'GET',
      Uri.parse('${_object(bucket, path)}?alt=media'),
    )..headers['Authorization'] = 'Firebase ${await signIn()}';
    final res = await _http.send(request);
    if (res.statusCode != 200) {
      _check(await http.Response.fromStream(res));
    }
    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = into.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (progress != null && total > 0) progress(got / total);
      }
    } finally {
      await sink.close();
    }
  }

  // ---------------------------------------------------------------- helpers

  Future<http.Response?> _send(
    Future<http.Response> Function() request, {
    bool allow404 = false,
  }) async {
    final http.Response res;
    try {
      res = await request();
    } on SocketException {
      throw SyncException('No connection to the server');
    }
    if (allow404 && res.statusCode == 404) return null;
    _check(res);
    return res;
  }

  void _check(http.Response res) {
    if (res.statusCode == 200) return;
    String message;
    try {
      final body = jsonDecode(res.body);
      final error = (body is List ? body.first : body) as Map;
      message = '${(error['error'] as Map?)?['message'] ?? res.body}';
    } catch (_) {
      message = res.body;
    }
    if (res.statusCode == 403) throw PermissionDenied(message);
    throw SyncException('Server error ${res.statusCode}: $message');
  }

  static Map<String, Object?> _json(String body) {
    try {
      final d = jsonDecode(body);
      if (d is Map<String, Object?>) return d;
    } on FormatException {
      // fall through
    }
    return const {};
  }

  static String _fieldPath(String name) =>
      RegExp(r'^[A-Za-z_][A-Za-z_0-9]*$').hasMatch(name) ? name : '`$name`';

  static String _timestamp(DateTime t) => t.toUtc().toIso8601String();

  /// Plain values to Firestore's typed values.
  static Map<String, Object?> encodeFields(Map<String, Object?> values) => {
    for (final e in values.entries) e.key: encodeValue(e.value),
  };

  static Map<String, Object?> encodeValue(Object? v) => switch (v) {
    null => {'nullValue': null},
    bool b => {'booleanValue': b},
    int i => {'integerValue': '$i'},
    double d => {'doubleValue': d},
    DateTime t => {'timestampValue': _timestamp(t)},
    Map m => {
      'mapValue': {'fields': encodeFields(m.cast<String, Object?>())},
    },
    List l => {
      'arrayValue': {
        'values': [for (final x in l) encodeValue(x)],
      },
    },
    _ => {'stringValue': v.toString()},
  };

  /// Firestore's typed values to plain ones (timestamps as DateTime).
  static Map<String, Object?> decodeFields(Map fields) => {
    for (final e in fields.entries)
      e.key as String: decodeValue(e.value as Map),
  };

  static Object? decodeValue(Map v) {
    if (v.containsKey('stringValue')) return v['stringValue'];
    if (v.containsKey('integerValue')) return int.parse('${v['integerValue']}');
    if (v.containsKey('doubleValue')) {
      return (v['doubleValue'] as num).toDouble();
    }
    if (v.containsKey('booleanValue')) return v['booleanValue'];
    if (v.containsKey('timestampValue')) {
      return DateTime.parse(v['timestampValue'] as String);
    }
    if (v.containsKey('mapValue')) {
      return decodeFields((v['mapValue'] as Map)['fields'] as Map? ?? const {});
    }
    if (v.containsKey('arrayValue')) {
      return [
        for (final x
            in ((v['arrayValue'] as Map)['values'] as List? ?? const []))
          decodeValue(x as Map),
      ];
    }
    return null;
  }
}
