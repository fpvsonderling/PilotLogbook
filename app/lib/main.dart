import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/documents.dart';
import 'data/local_db.dart';
import 'data/logbook.dart';
import 'data/photos.dart';
import 'data/push.dart';
import 'data/sync/sync_service.dart';
import 'data/update_check.dart';
import 'ui/home.dart';
import 'ui/services.dart';
import 'ui/settings_page.dart' show appVersion;
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  final db = LocalDb.open(p.join(dir.path, 'pilot_logbook.sqlite'));
  final photos = PhotoStore(p.join(dir.path, 'photos'));
  final documents = DocumentStore(p.join(dir.path, 'documents'));
  runApp(
    PilotLogbookApp(
      db: db,
      sync: SyncService(db, photos: photos, documents: documents),
    ),
  );
}

class PilotLogbookApp extends StatefulWidget {
  const PilotLogbookApp({
    super.key,
    required this.db,
    this.sync,
    this.updates,
    this.push = true,
  });

  final LocalDb db;

  /// Injected in tests; built from [db] otherwise.
  final SyncService? sync;

  /// Injected in tests; checks GitHub for [appVersion] otherwise.
  final UpdateChecker? updates;

  /// False in tests: no system notifications or Firebase push.
  final bool push;

  @override
  State<PilotLogbookApp> createState() => _PilotLogbookAppState();
}

class _PilotLogbookAppState extends State<PilotLogbookApp>
    with WidgetsBindingObserver {
  late final SyncService _sync = widget.sync ?? SyncService(widget.db);
  late final UpdateChecker _updates =
      widget.updates ?? UpdateChecker(current: appVersion);
  late final ValueNotifier<ThemeMode> _theme = ValueNotifier(
    ThemeChoice.parse(widget.db.setting(ThemeChoice.settingsKey)),
  )..addListener(_saveTheme);

  void _saveTheme() => widget.db.setSetting(
    ThemeChoice.settingsKey,
    ThemeChoice.store(_theme.value),
  );

  late final PushService? _push = widget.push
      ? PushService(widget.db, _sync)
      : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _push?.start();
    _sync.sync();
    _updates.check();
    // A window left open for days still learns about a new version.
    if (parseAppVersion(_updates.current) != null) {
      _updateTimer = Timer.periodic(
        const Duration(hours: 6),
        (_) => _updates.check(),
      );
    }
  }

  Timer? _updateTimer;

  @override
  void dispose() {
    _updateTimer?.cancel();
    _push?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _theme.dispose();
    super.dispose();
  }

  /// Sync (and look for a new version) whenever the window comes back to
  /// the front.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sync.sync();
      _updates.check();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Services(
      db: widget.db,
      logbook: Logbook(widget.db),
      sync: _sync,
      theme: _theme,
      updates: _updates,
      push: _push,
      child: ValueListenableBuilder(
        valueListenable: _theme,
        builder: (context, mode, _) => MaterialApp(
          title: 'Pilot Logbook',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          home: const HomePage(),
        ),
      ),
    );
  }
}
