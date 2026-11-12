import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/notifications.dart';
import '../data/push.dart';
import '../data/sync/sync_service.dart';
import '../data/update_check.dart';
import '../data/weather.dart';

/// Hands the database, queries and sync to every screen.
class Services extends InheritedWidget {
  const Services({
    super.key,
    required this.db,
    required this.logbook,
    required this.sync,
    required this.theme,
    this.updates,
    this.push,
    this.weather,
    required super.child,
  });

  final LocalDb db;
  final Logbook logbook;
  final SyncService sync;

  /// Light / dark / system, chosen in Settings and saved on this device.
  final ValueNotifier<ThemeMode> theme;

  /// Tells when a newer app version has been published (none in tests).
  final UpdateChecker? updates;

  /// Push and desktop notifications (none in tests).
  final PushService? push;

  /// What this key's person wants to be notified about, and the bell.
  Notifications get notifications => Notifications(
    db,
    me: sync.me,
    admin: sync.isAdmin,
    viewer: sync.readOnly,
  );

  /// Forecasts for the flight form (none: the weather card is hidden).
  final WeatherService? weather;

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
      db != oldWidget.db ||
      sync != oldWidget.sync ||
      theme != oldWidget.theme ||
      updates != oldWidget.updates ||
      push != oldWidget.push ||
      weather != oldWidget.weather;
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
