import 'dart:io';

import '../local_db.dart';
import '../schema.dart';
import 'firebase_client.dart';
import 'sync_errors.dart';

/// Who the access key belongs to, as the security rules see it
/// (firebase/firestore.rules): the same rights the Sheets script gave.
class FirebaseAccount {
  const FirebaseAccount({
    required this.admin,
    required this.readOnly,
    required this.me,
  });

  final bool admin;
  final bool readOnly;

  /// People id of a person's own key, '' for the master and shared keys.
  final String me;
}

/// Tables only the admin adds to and changes (adminOnly in the rules).
const adminOnlyTables = {'documents', 'maintenance_intervals', 'projects'};

/// Syncs the local database with Cloud Firestore: every table a
/// collection, every row a document named by its id, plus server_time
/// (when Firestore got it). meta/changes holds, per table, the time of its
/// last change, so a sync with nothing new reads one document.
///
/// The local sync_state keeps, per table, the server_time (in microseconds)
/// of the newest row this device has; server_seq of a row is its own.
class FirebaseSync {
  FirebaseSync(this.db, this.client);

  final LocalDb db;
  final FirebaseClient client;

  static int micros(DateTime t) => t.toUtc().microsecondsSinceEpoch;

  static DateTime fromMicros(int m) =>
      DateTime.fromMicrosecondsSinceEpoch(m, isUtc: true);

  /// Reads the key's member document and person: who this is.
  Future<FirebaseAccount> account() async {
    await client.signIn();
    final member = await client.get('members/${client.uid}');
    if (member == null || member['active'] != true) {
      throw SyncException(
        'Access key not valid or turned off. Ask the administrator.',
      );
    }
    final kind = member['kind'];
    if (kind == 'master') {
      return const FirebaseAccount(admin: true, readOnly: false, me: '');
    }
    if (kind != 'person') {
      return const FirebaseAccount(admin: false, readOnly: false, me: '');
    }
    final me = member['person_id'] as String? ?? '';
    final Map<String, Object?>? person;
    try {
      person = await client.get('people/$me');
    } on PermissionDenied {
      throw SyncException(
        'Access key not valid or turned off. Ask the administrator.',
      );
    }
    final roles = '${person?['roles'] ?? ''}'
        .split(',')
        .map((r) => r.trim())
        .toSet();
    final viewer = roles.contains('viewer');
    return FirebaseAccount(
      admin: !viewer && roles.contains('admin'),
      readOnly: viewer,
      me: me,
    );
  }

  /// Uploads every dirty row (except [skip]: photos not uploaded yet), then
  /// downloads what changed. Returns (pushed, pulled).
  Future<(int, int)> run(
    FirebaseAccount a, {
    Map<TableDef, Set<String>> skip = const {},
  }) async {
    final pushed = await _push(a, skip);
    final pulled = await _pull(a);
    return (pushed, pulled);
  }

  // ------------------------------------------------------------------ push

  Future<int> _push(FirebaseAccount a, Map<TableDef, Set<String>> skip) async {
    final pending = <(TableDef, DbRow)>[];
    for (final t in Tables.all) {
      for (final r in db.dirtyRows(t)) {
        if (skip[t]?.contains(r['id']) ?? false) continue;
        // What the rules refuse anyway is dropped here, without a request.
        if (a.readOnly || (!a.admin && adminOnlyTables.contains(t.name))) {
          await _refused(t, r['id'] as String);
          continue;
        }
        pending.add((t, _prepare(t, r, a)));
      }
    }
    var pushed = 0;
    const chunk = 200;
    for (var i = 0; i < pending.length; i += chunk) {
      final part = pending.sublist(
        i,
        i + chunk > pending.length ? pending.length : i + chunk,
      );
      try {
        final at = await client.commit(_writes(part));
        _accepted(part, at);
        pushed += part.length;
      } on PermissionDenied {
        // One refused row fails the whole commit: send them one by one.
        for (final one in part) {
          try {
            final at = await client.commit(_writes([one]));
            _accepted([one], at);
            pushed++;
          } on PermissionDenied {
            await _refused(one.$1, one.$2['id'] as String);
          }
        }
      }
    }
    return pushed;
  }

  /// The row as it is sent: a new row of a non-admin key is marked as
  /// theirs (the script did that from the link), and a person's change of
  /// their own competency clears verified.
  DbRow _prepare(TableDef t, DbRow r, FirebaseAccount a) {
    final out = {...r}..remove('server_seq');
    if (!a.admin) {
      if (r['server_seq'] == null) {
        out['created_by'] = a.me.isEmpty ? null : a.me;
      }
      if (Tables.personal.contains(t)) {
        out['verified'] = null;
        out['verified_by'] = null;
      }
    }
    return out;
  }

  List<Map<String, Object?>> _writes(List<(TableDef, DbRow)> rows) => [
    for (final (t, r) in rows) client.upsert('${t.name}/${r['id']}', r),
    client.stamp('meta/changes', {for (final (t, _) in rows) t.name}),
  ];

  void _accepted(List<(TableDef, DbRow)> rows, DateTime at) {
    db.transaction(() {
      for (final (t, r) in rows) {
        db.markSynced(
          t,
          r['id'] as String,
          r['updated_at'] as String,
          micros(at),
        );
      }
    });
  }

  /// The rules refused the row: forget the local edit and take the stored
  /// version, if there is one.
  Future<void> _refused(TableDef t, String id) async {
    Map<String, Object?>? stored;
    try {
      stored = await client.get('${t.name}/$id');
    } on PermissionDenied {
      stored = null;
    }
    db.transaction(() {
      db.dropLocalChange(t, id);
      if (stored != null) db.applyRemote(t, _row(stored));
    });
  }

  // ------------------------------------------------------------------ pull

  Future<int> _pull(FirebaseAccount a) async {
    final changes = await client.get('meta/changes') ?? const {};
    var pulled = 0;
    for (final t in Tables.all) {
      final changed = changes[t.name];
      if (changed is! DateTime) continue;
      final since = db.lastSeq(t);
      if (micros(changed) <= since) continue;
      final personalOnly = Tables.personal.contains(t) && !a.admin;
      if (personalOnly && a.me.isEmpty) {
        db.setLastSeq(t, micros(changed));
        continue;
      }
      final docs = personalOnly
          ? await client.query(t.name, equals: MapEntry('person_id', a.me))
          : await client.query(
              t.name,
              after: since > 0 ? fromMicros(since) : null,
            );
      var newest = since;
      db.transaction(() {
        for (final d in docs) {
          final r = _row(d);
          final s = r['server_seq'] as int? ?? 0;
          if (personalOnly && s <= since) continue;
          if (s > newest) newest = s;
          db.applyRemote(t, r);
          pulled++;
        }
        if (micros(changed) > newest) newest = micros(changed);
        db.setLastSeq(t, newest);
      });
    }
    return pulled;
  }

  /// A Firestore document as a row for [LocalDb.applyRemote].
  static Map<String, Object?> _row(Map<String, Object?> d) {
    final at = d['server_time'];
    return {...d, 'server_seq': at is DateTime ? micros(at) : null};
  }

  // --------------------------------------------------------------- members

  /// The access key of a person, made by the admin: their existing key, or
  /// with [renew] (or when they have none) a new one; renewing turns their
  /// other keys off.
  Future<String> personKey(String personId, {bool renew = false}) async {
    await client.signIn();
    final existing = await client.query(
      'members',
      equals: MapEntry('person_id', personId),
    );
    if (!renew) {
      for (final m in existing) {
        final key = m['key'];
        if (m['active'] == true && key is String && key.isNotEmpty) return key;
      }
    }
    final key = client.key.fresh();
    final uid = await client.createAccount(key);
    await client.commit([
      client.upsert('members/$uid', {
        'uid': uid,
        'kind': 'person',
        'person_id': personId,
        'active': true,
        'key': key.encode(),
      }, stampField: 'created_at'),
      for (final m in existing)
        if (m['uid'] is String && m['active'] == true)
          client.upsert('members/${m['uid']}', {
            ...m,
            'active': false,
          }, stampField: 'turned_off_at'),
    ]);
    return key.encode();
  }

  // ----------------------------------------------------------------- files

  /// Bucket of the project's Cloud Storage (written by the migration).
  Future<String> bucket() async {
    final config = await client.get('meta/config');
    final b = config?['bucket'];
    if (b is String && b.isNotEmpty) return b;
    return '${client.key.projectId}.firebasestorage.app';
  }

  Future<void> upload(String path, File file, String mime) async =>
      client.upload(await bucket(), path, file, mime);

  Future<void> download(
    String path,
    File into, {
    void Function(double)? progress,
  }) async => client.download(await bucket(), path, into, progress: progress);
}
