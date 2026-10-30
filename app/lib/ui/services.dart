import 'package:flutter/widgets.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/sync/sync_service.dart';

/// Hands the database, queries and sync to every screen.
class Services extends InheritedWidget {
  const Services({
    super.key,
    required this.db,
    required this.logbook,
    required this.sync,
    required super.child,
  });

  final LocalDb db;
  final Logbook logbook;
  final SyncService sync;

  static Services of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Services>()!;

  /// Changing and deleting saved data is for the admin, and for a person
  /// with their own link on the rows they added; others do not see those
  /// controls.
  bool get isAdmin => sync.isAdmin;
  bool canChange(DbRow row) => sync.canChange(row);

  @override
  bool updateShouldNotify(Services oldWidget) =>
      db != oldWidget.db || sync != oldWidget.sync;
}

/// Rebuilds [builder] whenever the local database or the sync state (such
/// as the admin role) changes.
class DbBuilder extends StatelessWidget {
  const DbBuilder({super.key, required this.builder});
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      Services.of(context).db.changes,
      Services.of(context).sync,
    ]),
    builder: (context, _) => builder(context),
  );
}
