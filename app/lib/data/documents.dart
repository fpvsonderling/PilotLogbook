import 'dart:io';

import 'package:path/path.dart' as p;

import 'local_db.dart';

/// Copies of the documents (the documents tab) kept on this device, so they
/// open offline and are downloaded from Drive only once, and again only
/// when the file in Drive changes. Each document has its own folder, named
/// by its row id, holding the file under its own name and a `.version`
/// note of which Drive file and version that is.
class DocumentStore {
  DocumentStore(this.dir);

  final String dir;

  Directory folder(String id) => Directory(p.join(dir, id));

  File _versionFile(String id) => File(p.join(dir, id, '.version'));

  /// Which file and version the row asks for; a copy of another one is old.
  static String versionOf(DbRow row) {
    final drive = row['drive_file_id'] as String? ?? '';
    final where = drive.isNotEmpty ? drive : row['storage_path'] ?? '';
    return '$where|${row['file_version'] ?? ''}';
  }

  /// Whether the row has a file (in Drive or in Firebase), not only a link.
  static bool hasFile(DbRow row) =>
      (row['drive_file_id'] as String? ?? '').isNotEmpty ||
      (row['storage_path'] as String? ?? '').isNotEmpty;

  /// The name the file is saved and opened under, so the system picks the
  /// right program from its extension.
  static String fileName(DbRow row) {
    final raw = (row['file_name'] as String? ?? '').trim();
    final name = raw.isNotEmpty ? raw : (row['title'] as String? ?? 'document');
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    return safe.isEmpty || safe.startsWith('.') ? 'document$safe' : safe;
  }

  /// This device's copy of the row's current file, or null.
  File? cached(DbRow row) {
    final id = row['id'] as String;
    final version = _versionFile(id);
    if (!version.existsSync()) return null;
    if (version.readAsStringSync() != versionOf(row)) return null;
    final f = File(p.join(dir, id, fileName(row)));
    return f.existsSync() ? f : null;
  }

  /// Whether this device has a copy, maybe of an older version.
  bool hasAnyCopy(DbRow row) {
    final d = folder(row['id'] as String);
    return d.existsSync() &&
        d.listSync().whereType<File>().any(
          (f) => !p.basename(f.path).startsWith('.'),
        );
  }

  /// The file a download writes to before [finish] makes it the copy.
  File partFile(DbRow row) =>
      File(p.join(dir, row['id'] as String, '.download'));

  /// Makes the downloaded [partFile] the row's copy, replacing older ones.
  File finish(DbRow row) => _install(row, partFile(row), move: true);

  /// Keeps a file picked on this device as the row's copy (the admin's own
  /// upload need not come back down).
  File keep(DbRow row, File source) => _install(row, source, move: false);

  File _install(DbRow row, File source, {required bool move}) {
    final id = row['id'] as String;
    final d = folder(id)..createSync(recursive: true);
    final target = File(p.join(d.path, fileName(row)));
    for (final f in d.listSync().whereType<File>()) {
      if (f.path != source.path && f.path != target.path) f.deleteSync();
    }
    if (move) {
      if (target.existsSync()) target.deleteSync();
      source.renameSync(target.path);
    } else if (source.absolute.path != target.absolute.path) {
      source.copySync(target.path);
    }
    _versionFile(id).writeAsStringSync(versionOf(row));
    return target;
  }

  /// Removes copies of documents that are no longer in the list.
  void prune(Iterable<String> keepIds) {
    final root = Directory(dir);
    if (!root.existsSync()) return;
    final keep = keepIds.toSet();
    for (final d in root.listSync().whereType<Directory>()) {
      if (!keep.contains(p.basename(d.path))) d.deleteSync(recursive: true);
    }
  }

  /// Bytes the copies take on this device.
  int bytesUsed() {
    final root = Directory(dir);
    if (!root.existsSync()) return 0;
    return root
        .listSync(recursive: true)
        .whereType<File>()
        .fold(0, (n, f) => n + f.lengthSync());
  }
}

/// The Drive file id in a Drive or Docs link, or a bare id; null otherwise.
String? driveFileId(String link) {
  final s = link.trim();
  for (final re in [
    RegExp(r'/d/([A-Za-z0-9_-]{10,})'),
    RegExp(r'[?&]id=([A-Za-z0-9_-]{10,})'),
    RegExp(r'^([A-Za-z0-9_-]{20,})$'),
  ]) {
    final m = re.firstMatch(s);
    if (m != null) return m.group(1);
  }
  return null;
}

/// The type Drive is told when the admin uploads a file, by its extension.
String mimeTypeOf(String fileName) => switch (p
    .extension(fileName)
    .toLowerCase()) {
  '.pdf' => 'application/pdf',
  '.doc' => 'application/msword',
  '.docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls' => 'application/vnd.ms-excel',
  '.xlsx' =>
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt' => 'application/vnd.ms-powerpoint',
  '.pptx' =>
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.jpg' || '.jpeg' => 'image/jpeg',
  '.png' => 'image/png',
  '.txt' => 'text/plain',
  '.csv' => 'text/csv',
  '.zip' => 'application/zip',
  '.mp4' => 'video/mp4',
  _ => 'application/octet-stream',
};

/// "2.4 MB" and the like.
String formatBytes(num? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}
