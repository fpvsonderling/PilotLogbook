class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The old Google Sheets script answered that the data moved to Firebase,
/// with this device's new access key.
class MovedToFirebase implements Exception {
  MovedToFirebase(this.accessKey);
  final String accessKey;
}
