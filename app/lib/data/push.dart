/// Getting notifications onto the screen:
/// - phones (Android, iPhone): this device registers with Firebase Cloud
///   Messaging in push_devices, and Code.gs sendNotifications() sends to
///   it, also while the app is closed;
/// - Windows and Mac (no Firebase push there): after each sync the app
///   shows a system notification for what is new in the bell.
library;

import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'local_db.dart';
import 'notifications.dart';
import 'schema.dart';
import 'sync/sync_service.dart';

class PushService {
  PushService(this.db, this.sync);

  final LocalDb db;
  final SyncService sync;

  /// The page a tapped notification asks for (its menu label).
  final openPage = ValueNotifier<String?>(null);

  static bool get isPhone => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// This installation's row in push_devices.
  static const installKey = 'install_id';

  /// '0' when push is switched off on this phone.
  static const deviceKey = 'push_on_device';

  /// What was last registered: "owner token", to skip unchanged ones.
  static const registeredKey = 'push_registered';

  final _local = FlutterLocalNotificationsPlugin();
  bool _localReady = false;
  bool _wasRunning = false;
  bool _started = false;
  StreamSubscription<String>? _tokenRefresh;

  Notifications notifications() => Notifications(
    db,
    me: sync.me,
    admin: sync.isAdmin,
    viewer: sync.readOnly,
  );

  bool get onThisDevice => db.setting(deviceKey) != '0';

  Future<void> setOnThisDevice(bool on) async {
    db.setSetting(deviceKey, on ? '1' : '0');
    await update();
  }

  /// Called once at app start.
  Future<void> start() async {
    // Widget tests have no notification plugins.
    if (_started ||
        kIsWeb ||
        Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    _started = true;
    try {
      await _initLocal();
    } catch (e) {
      debugPrint('Local notifications: $e');
    }
    sync.addListener(_onSync);
  }

  void dispose() {
    sync.removeListener(_onSync);
    _tokenRefresh?.cancel();
    openPage.dispose();
  }

  /// After a sync finished: desktop notifications for what is new, and
  /// on phones the registration kept up to date.
  void _onSync() {
    final running = sync.running;
    final finished = _wasRunning && !running;
    _wasRunning = running;
    if (!finished || sync.lastError != null) return;
    if (isDesktop) _showNew();
    if (isPhone) unawaited(update());
  }

  Future<void> _initLocal() async {
    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: 'Pilot Logbook',
          appUserModelId: 'Yavorskyi.PilotLogbook',
          guid: '6c3f2b8e-4a1d-4f5e-9b7a-2d8c1e0f3a51',
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        if ((r.payload ?? '').isNotEmpty) openPage.value = r.payload;
      },
    );
    await _local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'reminders',
            'Reminders',
            description: 'Faults, maintenance and competencies',
            importance: Importance.high,
          ),
        );
    _localReady = true;
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Reminders',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
    macOS: DarwinNotificationDetails(),
  );

  int _nextId = 0;

  Future<void> _show(String title, String body, String page) async {
    if (!_localReady) return;
    await _local.show(
      id: _nextId++,
      title: title,
      body: body,
      notificationDetails: _details,
      payload: page,
    );
  }

  /// Windows / Mac: a system notification for each new bell item (one
  /// summary when there are many).
  void _showNew() {
    final n = notifications();
    if (!n.available) return;
    final fresh = n.takeNew();
    if (fresh.isEmpty || !onThisDevice) return;
    if (Platform.isMacOS && fresh.isNotEmpty) {
      unawaited(
        _local
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, sound: true),
      );
    }
    if (fresh.length > 3) {
      unawaited(
        _show(
          '${fresh.length} new notifications',
          fresh.map((i) => i.title).take(5).join('\n'),
          fresh.first.page,
        ),
      );
      return;
    }
    for (final i in fresh) {
      unawaited(_show(i.title, i.body, i.page));
    }
  }

  // ----------------------------------------------------------- phones

  /// Registers this phone for push, or removes it when the person wants
  /// nothing (or switched push off here). Safe to call often.
  Future<void> update() async {
    if (!isPhone) return;
    final n = notifications();
    final owner = n.owner;
    final wanted =
        owner != null && onThisDevice && n.prefs().on.values.any((on) => on);
    final rowId = _installId();
    try {
      if (!wanted) {
        final row = db.byId(Tables.pushDevices, rowId);
        if (row != null && row['deleted'] != 1) {
          db.delete(Tables.pushDevices, rowId);
          db.setSetting(registeredKey, null);
          unawaited(sync.sync());
        }
        return;
      }
      final token = await _token();
      if (token == null) return;
      final registered = '$owner $token';
      if (db.setting(registeredKey) == registered &&
          db.byId(Tables.pushDevices, rowId)?['deleted'] == 0) {
        return;
      }
      db.save(Tables.pushDevices, {
        'id': rowId,
        'person_id': owner,
        'token': token,
        'platform': Platform.isIOS ? 'ios' : 'android',
        'device_name': Platform.localHostname,
      });
      db.setSetting(registeredKey, registered);
      unawaited(sync.sync());
    } catch (e) {
      debugPrint('Push registration: $e');
    }
  }

  String _installId() {
    var id = db.setting(installKey);
    if (id == null || id.isEmpty) {
      id = LocalDb.newId();
      db.setSetting(installKey, id);
    }
    return id;
  }

  /// This phone's Firebase Cloud Messaging token; null while push is not
  /// set up in Firebase (Code.gs setupPush) or the person said no.
  Future<String?> _token() async {
    if (Firebase.apps.isEmpty) {
      final c = await sync.pushConfig();
      if (c == null) return null;
      final ios = Platform.isIOS;
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey:
              '${c[ios ? 'push_ios_api_key' : 'push_android_api_key'] ?? c['api_key']}',
          appId: '${c[ios ? 'push_ios_app_id' : 'push_android_app_id']}',
          messagingSenderId: '${c['push_sender_id']}',
          projectId: '${c['project_id']}',
          iosBundleId: ios ? 'com.yavorskyi.pilotlogbook' : null,
        ),
      );
      _listen();
    }
    final m = FirebaseMessaging.instance;
    final perm = await m.requestPermission();
    if (perm.authorizationStatus == AuthorizationStatus.denied) return null;
    if (Platform.isIOS && await m.getAPNSToken() == null) return null;
    // The registration token Code.gs sends to (FCM HTTP v1 "token").
    // ignore: deprecated_member_use
    return m.getToken();
  }

  void _listen() {
    final m = FirebaseMessaging.instance;
    // ignore: deprecated_member_use
    _tokenRefresh = m.onTokenRefresh.listen((_) {
      db.setSetting(registeredKey, null);
      unawaited(update());
    });
    // While the app is open the phone shows nothing by itself.
    FirebaseMessaging.onMessage.listen((msg) {
      final n = msg.notification;
      if (n == null) return;
      unawaited(
        _show(n.title ?? '', n.body ?? '', '${msg.data['page'] ?? ''}'),
      );
    });
    FirebaseMessaging.onMessageOpenedApp.listen(_opened);
    unawaited(
      m.getInitialMessage().then((msg) {
        if (msg != null) _opened(msg);
      }),
    );
    unawaited(
      m.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: true,
        sound: false,
      ),
    );
  }

  void _opened(RemoteMessage msg) {
    final page = '${msg.data['page'] ?? ''}';
    if (page.isNotEmpty) openPage.value = page;
  }
}
