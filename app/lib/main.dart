import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/local_db.dart';
import 'data/logbook.dart';
import 'data/sync/sync_service.dart';
import 'ui/home.dart';
import 'ui/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  final db = LocalDb.open(p.join(dir.path, 'pilot_logbook.sqlite'));
  runApp(PilotLogbookApp(db: db));
}

class PilotLogbookApp extends StatefulWidget {
  const PilotLogbookApp({super.key, required this.db, this.sync});

  final LocalDb db;

  /// Injected in tests; built from [db] otherwise.
  final SyncService? sync;

  @override
  State<PilotLogbookApp> createState() => _PilotLogbookAppState();
}

class _PilotLogbookAppState extends State<PilotLogbookApp>
    with WidgetsBindingObserver {
  late final SyncService _sync = widget.sync ?? SyncService(widget.db);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync.sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Sync again whenever the window comes back to the front.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _sync.sync();
  }

  @override
  Widget build(BuildContext context) {
    return Services(
      db: widget.db,
      logbook: Logbook(widget.db),
      sync: _sync,
      child: MaterialApp(
        title: 'Pilot Logbook',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF00A0B0),
          visualDensity: VisualDensity.compact,
        ),
        home: const HomePage(),
      ),
    );
  }
}
