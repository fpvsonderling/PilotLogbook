import 'package:flutter/material.dart';

import '../data/notifications.dart';
import '../data/push.dart';
import '../data/schema.dart';
import 'services.dart';
import 'theme.dart';

/// The bell at the top: what the person's notification settings pick
/// out, with a count of what they did not open yet. Hidden for a viewer
/// and for a key without a person.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key, required this.onOpen});

  /// Opens an app page by its menu label.
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => DbBuilder(
    builder: (context) {
      final n = Services.of(context).notifications;
      if (!n.available) return const SizedBox.shrink();
      final items = n.inbox();
      final unseen = n.unseen(items).length;
      return IconButton(
        key: const Key('notification-bell'),
        tooltip: unseen == 0
            ? 'Notifications'
            : unseen == 1
            ? '1 new notification'
            : '$unseen new notifications',
        color: Colors.white,
        onPressed: () => _open(context, n, items),
        icon: Badge(
          isLabelVisible: unseen > 0,
          backgroundColor: AppPalette.gold,
          textColor: AppPalette.text,
          label: Text(
            '$unseen',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          child: Icon(
            items.isEmpty ? Icons.notifications_none : Icons.notifications,
          ),
        ),
      );
    },
  );

  Future<void> _open(
    BuildContext context,
    Notifications n,
    List<InboxItem> items,
  ) async {
    final unseen = n.unseen(items).map((i) => i.key).toSet();
    n.markSeen(items);
    Services.of(context).db.changes.notify();
    final page = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => _Inbox(items: items, unseen: unseen),
    );
    if (page != null) onOpen(page);
  }
}

class _Inbox extends StatelessWidget {
  const _Inbox({required this.items, required this.unseen});
  final List<InboxItem> items;
  final Set<String> unseen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Notifications',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context, 'Settings'),
                    icon: const Icon(Icons.tune),
                    label: const Text('Settings'),
                  ),
                ],
              ),
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 32),
                child: Text(
                  'Nothing needs you now. Choose what you want to hear '
                  'about under Settings > Notifications.',
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return ListTile(
                      key: Key('inbox-${item.key}'),
                      leading: Icon(
                        Icons.circle,
                        size: 12,
                        color: item.urgent ? scheme.error : AppPalette.gold,
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          fontWeight: unseen.contains(item.key)
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      subtitle: item.body.isEmpty ? null : Text(item.body),
                      onTap: () => Navigator.pop(context, item.page),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Settings > Notifications: what this person wants, and "My drones".
class NotificationSettings extends StatelessWidget {
  const NotificationSettings({super.key});

  @override
  Widget build(BuildContext context) => DbBuilder(
    builder: (context) {
      final services = Services.of(context);
      final n = services.notifications;
      if (!n.available) return const SizedBox.shrink();
      final prefs = n.prefs();
      final push = services.push;
      final types = [
        for (final t in notifyTypes)
          if (!t.admin || n.admin) t,
      ];
      void save(NotifyPrefs p) {
        n.save(p);
        push?.update();
      }

      final droneWise = types.any(
        (t) => droneTypes.contains(t.column) && prefs.wants(t.column),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Text('Notifications', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            PushService.isPhone
                ? 'Shown on this phone, also when the app is closed. '
                      'Reminders come at 07:00; nothing between 21:00 and '
                      '07:00.'
                : 'Shown in the bell at the top, and as a Windows / Mac '
                      'notification while the app is open. Phones get them '
                      'also when the app is closed.',
          ),
          if (push != null && PushService.isPhone)
            SwitchListTile(
              key: const Key('push-on-device'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Push notifications on this phone'),
              value: push.onThisDevice,
              onChanged: (v) async {
                await push.setOnThisDevice(v);
                services.db.changes.notify();
              },
            ),
          for (final t in types)
            SwitchListTile(
              key: Key('notify-${t.column}'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.title),
              subtitle: Text(
                droneTypes.contains(t.column) && !n.admin
                    ? '${t.subtitle}; my drones only'
                    : t.subtitle,
              ),
              value: prefs.wants(t.column),
              onChanged: (v) =>
                  save(prefs.copyWith(on: {...prefs.on, t.column: v})),
            ),
          if (!n.admin && droneWise) _MyDrones(n: n, prefs: prefs, save: save),
          if (n.admin)
            Text(
              'As an admin you get these for every drone.',
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
        ],
      );
    },
  );
}

class _MyDrones extends StatelessWidget {
  const _MyDrones({required this.n, required this.prefs, required this.save});
  final Notifications n;
  final NotifyPrefs prefs;
  final ValueChanged<NotifyPrefs> save;

  @override
  Widget build(BuildContext context) {
    final drones = n.db.rows(
      Tables.aircraft,
      where: 'COALESCE(active, 1) = 1',
      orderBy: 'name COLLATE NOCASE',
    );
    final recent = n.recentDrones();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('My drones', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          prefs.drones.isEmpty
              ? 'Tick the drones these notifications are about.'
              : 'Faults and maintenance of these drones.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in drones)
              FilterChip(
                key: Key('my-drone-${d['id']}'),
                label: Text(
                  'Drone ${d['name'] ?? ''}'
                  '${recent.contains(d['id']) ? ' · flown recently' : ''}',
                ),
                selected: prefs.drones.contains(d['id']),
                onSelected: (on) => save(
                  prefs.copyWith(
                    drones: on
                        ? {...prefs.drones, d['id'] as String}
                        : ({...prefs.drones}..remove(d['id'])),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
