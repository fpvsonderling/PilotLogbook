import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'schema.dart';

typedef DbRow = Map<String, Object?>;

/// Local SQLite copy of the spreadsheet. The app reads and writes only here;
/// [SyncService] moves changes between this database and Google Sheets.
class LocalDb {
  LocalDb._(this._db) {
    _migrate();
  }

  factory LocalDb.open(String path) => LocalDb._(sqlite3.open(path));

  factory LocalDb.inMemory() => LocalDb._(sqlite3.openInMemory());

  final Database _db;
  static const _uuid = Uuid();

  /// Fires after every write, local or from sync, so screens can reload.
  final changes = DbChanges();

  /// Overridable clock, for tests.
  DateTime Function() now = () => DateTime.now().toUtc();

  void _migrate() {
    for (final t in Tables.all) {
      final cols = [
        'id TEXT PRIMARY KEY',
        for (final c in t.allColumns.skip(1)) '${c.name} ${_sqlType(c.type)}',
        'dirty INTEGER NOT NULL DEFAULT 0',
      ];
      _db.execute('CREATE TABLE IF NOT EXISTS ${t.name} (${cols.join(', ')})');
      // Columns added to the schema later are added to existing databases.
      final existing = {
        for (final r in _db.select('PRAGMA table_info(${t.name})'))
          r['name'] as String,
      };
      for (final c in t.allColumns) {
        if (!existing.contains(c.name)) {
          _db.execute(
            'ALTER TABLE ${t.name} ADD COLUMN ${c.name} ${_sqlType(c.type)}',
          );
        }
      }
    }
    _db.execute(
      'CREATE TABLE IF NOT EXISTS sync_state '
      '(table_name TEXT PRIMARY KEY, last_seq INTEGER NOT NULL)',
    );
    _db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)',
    );
  }

  static String _sqlType(ColType t) => switch (t) {
    ColType.text => 'TEXT',
    ColType.integer => 'INTEGER',
    ColType.real => 'REAL',
  };

  void close() => _db.close();

  // ---------------------------------------------------------------- reads

  /// Rows that are not deleted, optionally filtered by [where].
  List<DbRow> rows(
    TableDef table, {
    String? where,
    List<Object?> args = const [],
    String? orderBy,
  }) {
    final sql = StringBuffer('SELECT * FROM ${table.name} WHERE deleted = 0');
    if (where != null) sql.write(' AND ($where)');
    if (orderBy != null) sql.write(' ORDER BY $orderBy');
    return [for (final r in _db.select(sql.toString(), args)) Map.of(r)];
  }

  DbRow? byId(TableDef table, String id) {
    final r = _db.select('SELECT * FROM ${table.name} WHERE id = ?', [id]);
    return r.isEmpty ? null : Map.of(r.first);
  }

  /// Raw query for reports and statistics.
  List<DbRow> select(String sql, [List<Object?> args = const []]) => [
    for (final r in _db.select(sql, args)) Map.of(r),
  ];

  // --------------------------------------------------------------- writes

  /// Inserts or updates a row made on this device and marks it for upload.
  /// Returns the row's id.
  String save(TableDef table, DbRow values) {
    final id = (values['id'] as String?) ?? _uuid.v4();
    final existing = byId(table, id);
    final row = <String, Object?>{
      for (final c in table.columns) c.name: existing?[c.name],
      ...{
        for (final e in values.entries)
          if (table.columns.any((c) => c.name == e.key)) e.key: e.value,
      },
      'id': id,
      'updated_at': now().toIso8601String(),
      'server_seq': existing?['server_seq'],
      'deleted': 0,
      'dirty': 1,
    };
    _write(table, row);
    changes.notify();
    return id;
  }

  void delete(TableDef table, String id) {
    _db.execute(
      'UPDATE ${table.name} SET deleted = 1, dirty = 1, updated_at = ? '
      'WHERE id = ?',
      [now().toIso8601String(), id],
    );
    changes.notify();
  }

  void _write(TableDef table, DbRow row) {
    final names = row.keys.toList();
    _db.execute(
      'INSERT OR REPLACE INTO ${table.name} (${names.join(', ')}) '
      'VALUES (${List.filled(names.length, '?').join(', ')})',
      [for (final n in names) row[n]],
    );
  }

  // ----------------------------------------------------------------- sync

  /// Rows changed on this device that the spreadsheet has not seen yet,
  /// in the shape sent to Apps Script (system + domain columns).
  List<DbRow> dirtyRows(TableDef table) => [
    for (final r in _db.select('SELECT * FROM ${table.name} WHERE dirty = 1'))
      {for (final n in table.columnNames) n: r[n]},
  ];

  /// Clears the dirty flag after the spreadsheet accepted a row. A row edited
  /// again while the upload ran keeps its flag, since its updated_at moved.
  void markSynced(TableDef table, String id, String updatedAt, int serverSeq) {
    _db.execute(
      'UPDATE ${table.name} SET dirty = 0, server_seq = ? '
      'WHERE id = ? AND updated_at = ?',
      [serverSeq, id, updatedAt],
    );
  }

  /// Applies a row pulled from the spreadsheet. The newer updated_at wins; a
  /// newer local edit stays and is uploaded on the next sync.
  void applyRemote(TableDef table, Map<String, Object?> remote) {
    final row = <String, Object?>{
      for (final c in table.allColumns) c.name: _fromSheet(c, remote[c.name]),
    };
    final id = row['id'] as String?;
    if (id == null || id.isEmpty) return;
    final local = byId(table, id);
    if (local != null && local['dirty'] == 1) {
      final localTs = local['updated_at'] as String? ?? '';
      final remoteTs = row['updated_at'] as String? ?? '';
      if (localTs.compareTo(remoteTs) > 0) return;
    }
    row['deleted'] = row['deleted'] ?? 0;
    row['dirty'] = 0;
    _write(table, row);
  }

  /// Sheets hand every value back as text; convert by the column's type.
  static Object? _fromSheet(Col col, Object? v) {
    if (v == null || (v is String && v.trim().isEmpty)) return null;
    return switch (col.type) {
      ColType.text => v.toString(),
      ColType.integer => v is num ? v.toInt() : int.tryParse(v.toString()),
      ColType.real =>
        v is num
            ? v.toDouble()
            : double.tryParse(v.toString().replaceAll(',', '.')),
    };
  }

  int lastSeq(TableDef table) {
    final r = _db.select(
      'SELECT last_seq FROM sync_state WHERE table_name = ?',
      [table.name],
    );
    return r.isEmpty ? 0 : r.first['last_seq'] as int;
  }

  void setLastSeq(TableDef table, int seq) {
    _db.execute(
      'INSERT OR REPLACE INTO sync_state (table_name, last_seq) VALUES (?, ?)',
      [table.name, seq],
    );
  }

  /// Wraps a batch of sync writes in one transaction and one notification.
  void transaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    changes.notify();
  }

  // ------------------------------------------------------------- settings

  String? setting(String key) {
    final r = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  void setSetting(String key, String? value) {
    _db.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', [
      key,
      value,
    ]);
  }
}

class DbChanges extends ChangeNotifier {
  void notify() => notifyListeners();
}
