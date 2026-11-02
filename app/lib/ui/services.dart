import 'package:flutter/material.dart';

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
    required this.theme,
    required super.child,
  });

  final LocalDb db;
  final Logbook logbook;
  final SyncService sync;

  /// Light / dark / system, chosen in Settings and saved on this device.
  final ValueNotifier<ThemeMode> theme;

  static Services of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Services>()!;

  /// Changing and deleting saved data is for the admin, and for a person
  /// with their own link on the rows they added; others do not see those
  /// controls.
  bool get isAdmin => sync.isAdmin;
  bool canChange(DbRow row) => sync.canChange(row);

  /// False for a viewer (read only key): add buttons are hidden.
  bool get canAdd => sync.canAdd;

  @override
  bool updateShouldNotify(Services oldWidget) =>
      db != oldWidget.db || sync != oldWidget.sync || theme != oldWidget.theme;
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

/// An add button that disappears for a viewer (read only key), also when
/// the role becomes known during a sync.
class AddButton extends StatelessWidget {
  const AddButton({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sync = Services.of(context).sync;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => sync.canAdd ? child : const SizedBox.shrink(),
    );
  }
}
