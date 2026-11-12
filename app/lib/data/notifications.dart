/// Notifications: what each person wants to hear about (notify_settings),
/// and the list behind the bell at the top of the app. Phones also get
/// them as push notifications, sent by Code.gs sendNotifications() with
/// the same rules:
/// - the admin gets everything until they switch it off, for every drone;
/// - anyone else gets nothing until they switch it on, and only for the
///   drones they tick under "My drones";
/// - a viewer (read only key) gets nothing.
library;

import 'dart:convert';

import 'competencies.dart';
import 'local_db.dart';
import 'logbook.dart';
import 'maintenance.dart';
import 'schema.dart';

/// One kind of notification a person switches on or off.
class NotifyType {
  const NotifyType(
    this.column,
    this.title,
    this.subtitle, {
    this.admin = false,
  });

  /// Column in notify_settings.
  final String column;
  final String title;
  final String subtitle;

  /// Only offered to the admin.
  final bool admin;
}

const notifyTypes = [
  NotifyType('faults', 'New faults', 'Right after a fault is reported'),
  NotifyType(
    'repairs',
    'Repairs waiting for the test',
    'When a fault is repaired and needs sign-off',
  ),
  NotifyType(
    'maintenance',
    'Maintenance due',
    'Drones and battery sets due soon or overdue, at 07:00',
  ),
  NotifyType(
    'competencies',
    'My competencies',
    '30 and 7 days before they expire, and on the day',
  ),
  NotifyType(
    'team_competencies',
    "Team's competencies",
    'Everyone\'s, 30 and 7 days before and on the day',
    admin: true,
  ),
];

/// Types that only concern the drones in "My drones".
const droneTypes = {'faults', 'repairs', 'maintenance'};

/// What one person wants.
class NotifyPrefs {
  const NotifyPrefs({
    required this.on,
    required this.drones,
    this.saved = false,
  });

  /// Column of [notifyTypes] -> wanted.
  final Map<String, bool> on;

  /// "My drones": aircraft ids. Not used for the admin (every drone).
  final Set<String> drones;

  /// False while the person never saved their choice (the defaults apply).
  final bool saved;

  bool wants(String column) => on[column] ?? false;

  NotifyPrefs copyWith({Map<String, bool>? on, Set<String>? drones}) =>
      NotifyPrefs(
        on: on ?? this.on,
        drones: drones ?? this.drones,
        saved: saved,
      );
}

/// One line in the bell's list.
class InboxItem {
  const InboxItem({
    required this.key,
    required this.title,
    required this.body,
    required this.page,
    this.urgent = false,
  });

  /// Stays the same while the thing it is about does not change, so the
  /// bell knows what was already seen.
  final String key;
  final String title;
  final String body;

  /// The app page it opens (its label in the menu).
  final String page;

  /// Overdue, expired or grounded: red rather than amber.
  final bool urgent;
}

class Notifications {
  Notifications(
    this.db, {
    required this.me,
    required this.admin,
    required this.viewer,
    DateTime Function()? today,
  }) : today = today ?? DateTime.now;

  final LocalDb db;

  /// People id of the key's person; null for the master and shared keys.
  final String? me;
  final bool admin;
  final bool viewer;
  final DateTime Function() today;

  /// The master admin key has no person: it keeps its settings as
  /// "master" (Code.gs treats it as an admin).
  static const master = 'master';

  /// Days in which a pilot's flights and daily checks count for the
  /// drones offered under "My drones".
  static const recentDays = 30;

  /// Whose settings these are; null when the key cannot have any (viewer,
  /// shared key).
  String? get owner {
    if (viewer) return null;
    if (me != null) return me;
    return admin ? master : null;
  }

  bool get available => owner != null;

  static String rowId(String owner) => 'notify-$owner';

  NotifyPrefs prefs() {
    final o = owner;
    final row = o == null ? null : db.byId(Tables.notifySettings, rowId(o));
    if (row == null || row['deleted'] == 1) {
      return NotifyPrefs(
        on: {for (final t in notifyTypes) t.column: admin && o != null},
        drones: const {},
      );
    }
    return NotifyPrefs(
      on: {
        for (final t in notifyTypes)
          t.column: row[t.column] == 1 && (admin || !t.admin),
      },
      drones: _list(row['aircraft_ids']).toSet(),
      saved: true,
    );
  }

  void save(NotifyPrefs p) {
    final o = owner;
    if (o == null) return;
    db.save(Tables.notifySettings, {
      'id': rowId(o),
      'person_id': o,
      for (final t in notifyTypes) t.column: p.wants(t.column) ? 1 : 0,
      'aircraft_ids': p.drones.join(','),
    });
  }

  /// Drones the person flew or checked in the last [recentDays] days.
  Set<String> recentDrones() {
    final id = me;
    if (id == null) return {};
    final t = today();
    final from = DateTime(t.year, t.month, t.day - recentDays);
    final day =
        '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')}';
    return {
      for (final r in db.select(
        'SELECT DISTINCT aircraft_id FROM flights WHERE deleted = 0 '
        'AND date >= ? AND ? IN (rp_id, pa_id, spotter_id) '
        'UNION SELECT DISTINCT aircraft_id FROM daily_checks_fb3 '
        'WHERE deleted = 0 AND checked_at >= ? AND pilot_id = ? '
        'UNION SELECT DISTINCT aircraft_id FROM daily_checks_m30t '
        'WHERE deleted = 0 AND checked_at >= ? AND pilot_id = ?',
        [day, id, day, id, day, id],
      ))
        if ((r['aircraft_id'] as String?)?.isNotEmpty ?? false)
          r['aircraft_id'] as String,
    };
  }

  // ------------------------------------------------------------------ bell

  /// Days a new fault stays in the bell.
  static const faultDays = 14;

  /// What the bell lists now, the most urgent first.
  List<InboxItem> inbox() {
    if (!available) return const [];
    final p = prefs();
    final mine = p.drones;
    bool forDrone(String? aircraftId, String? batteryId) {
      if (admin) return true;
      if ((aircraftId ?? '').isNotEmpty) return mine.contains(aircraftId);
      if ((batteryId ?? '').isNotEmpty) {
        final b = db.byId(Tables.batteries, batteryId!);
        return _list(b?['aircraft_ids']).any(mine.contains);
      }
      return false;
    }

    final names = {
      for (final r in db.rows(Tables.aircraft)) r['id']: r['name'] ?? '',
    };
    final people = {
      for (final r in db.rows(Tables.people)) r['id']: r['name'] ?? '',
    };
    final out = <InboxItem>[];

    final t = today();
    final since = DateTime(t.year, t.month, t.day - faultDays);
    final sinceText =
        '${since.year}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')}';
    for (final c in Logbook(db).faultCases()) {
      if (c.status == FaultStatus.closed) continue;
      final f = c.fault;
      final what = (f['aircraft_id'] as String?)?.isNotEmpty ?? false
          ? 'drone ${names[f['aircraft_id']] ?? ''}'
          : (f['equipment'] as String?)?.isNotEmpty ?? false
          ? f['equipment'] as String
          : 'equipment';
      final byMe = me != null && f['discovered_by_id'] == me;
      final drone = forDrone(
        f['aircraft_id'] as String?,
        f['battery_id'] as String?,
      );
      if (c.status == FaultStatus.repaired) {
        if (p.wants('repairs') && (byMe || drone)) {
          out.add(
            InboxItem(
              key: 'r:${c.id}:${c.repairs.length}',
              title: 'Repaired, waiting for the test: $what',
              body: (c.repairs.last['work_performed'] as String?) ?? '',
              page: 'Fault Repair',
            ),
          );
        }
        continue;
      }
      if (!p.wants('faults') || byMe || !drone) continue;
      if (c.reportedAt.compareTo(sinceText) < 0) continue;
      final by = people[f['discovered_by_id']] ?? '';
      out.add(
        InboxItem(
          key: 'f:${c.id}',
          title: '${c.grounded ? 'Grounded' : 'New fault'}: $what',
          body: [
            if ('$by'.isNotEmpty) '$by:',
            f['description'] ?? '',
          ].join(' '),
          page: 'Fault Repair',
          urgent: c.grounded,
        ),
      );
    }

    if (p.wants('maintenance')) {
      final log = MaintenanceLog(db, today: today);
      for (final d in [...log.drones(), ...log.batterySets()]) {
        if (d.level == DueLevel.ok) continue;
        if (!forDrone(d.battery ? null : d.id, d.battery ? d.id : null)) {
          continue;
        }
        final over = d.level == DueLevel.overdue;
        final sections = d.due;
        out.add(
          InboxItem(
            key: 'm:${d.id}:${d.level.name}:${d.last?.id ?? ''}',
            title:
                '${over ? 'Maintenance overdue' : 'Maintenance due soon'}: '
                '${d.title}',
            body: [
              for (final s in sections) '${s.section.title}: ${s.describe()}',
            ].join('\n'),
            page: 'Maintenance',
            urgent: over,
          ),
        );
      }
    }

    final own = p.wants('competencies');
    final team = admin && p.wants('team_competencies');
    if (own || team) {
      final day = today();
      for (final c in CompetencyLog(db, today: today).alerts()) {
        final mineToo = me != null && c.personId == me;
        if (!(mineToo ? own : team)) continue;
        final status = c.status(day);
        final who = mineToo ? 'Your' : '${people[c.personId] ?? 'Someone'}:';
        out.add(
          InboxItem(
            key: 'c:${c.id}:${status.name}:${c.expiresOn}',
            title: '$who ${c.type.isEmpty ? 'competency' : c.type}',
            body: c.describe(day),
            page: 'Competencies',
            urgent: status == CompetencyStatus.expired,
          ),
        );
      }
    }

    out.sort((a, b) => (b.urgent ? 1 : 0).compareTo(a.urgent ? 1 : 0));
    return out;
  }

  // ------------------------------------------------- seen and shown items

  static const seenKey = 'notify_seen';
  static const shownKey = 'notify_shown';

  Set<String> _keys(String setting) {
    final v = db.setting(setting);
    if (v == null) return {};
    try {
      return {for (final k in jsonDecode(v) as List) '$k'};
    } on FormatException {
      return {};
    }
  }

  /// Items not opened in the bell yet.
  List<InboxItem> unseen([List<InboxItem>? items]) {
    final seen = _keys(seenKey);
    return [
      for (final i in items ?? inbox())
        if (!seen.contains(i.key)) i,
    ];
  }

  /// The bell was opened: everything in it now counts as seen.
  void markSeen([List<InboxItem>? items]) => db.setSetting(
    seenKey,
    jsonEncode([for (final i in items ?? inbox()) i.key]),
  );

  /// Items that appeared since the last call, for a desktop notification;
  /// the first call on a device only remembers what is there.
  List<InboxItem> takeNew([List<InboxItem>? items]) {
    final now = items ?? inbox();
    final first = db.setting(shownKey) == null;
    final shown = _keys(shownKey);
    db.setSetting(shownKey, jsonEncode([for (final i in now) i.key]));
    if (first) return const [];
    return [
      for (final i in now)
        if (!shown.contains(i.key)) i,
    ];
  }

  static List<String> _list(Object? text) => '${text ?? ''}'
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}
