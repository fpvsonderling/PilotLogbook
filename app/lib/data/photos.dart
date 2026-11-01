import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'local_db.dart';
import 'schema.dart';

/// Fault photos as files next to the database, named by their fault_photos
/// row id. A photo taken offline waits here until a sync uploads it to
/// Drive; a photo from another device is downloaded the first time it is
/// shown and kept for offline use.
class PhotoStore {
  PhotoStore(this.dir);

  final String dir;

  File file(String photoId) => File(p.join(dir, '$photoId.jpg'));

  /// Saves the picture and its fault_photos row (marked for upload).
  String add(
    LocalDb db, {
    required String faultId,
    String? repairId,
    required Uint8List bytes,
  }) {
    final id = db.save(Tables.faultPhotos, {
      'fault_id': faultId,
      'repair_id': repairId ?? '',
    });
    final f = file(id);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return id;
  }

  /// Rows whose picture is only on this device so far.
  List<DbRow> pendingUploads(LocalDb db) => [
    for (final r in db.rows(
      Tables.faultPhotos,
      where: "COALESCE(drive_file_id, '') = ''",
    ))
      if (file(r['id'] as String).existsSync()) r,
  ];
}
