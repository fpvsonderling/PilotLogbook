import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import '../data/sync/sync_service.dart' show KeyStatus;
import 'intervals_tab.dart';
import 'services.dart';

/// People, drones, batteries and mission types: the lists every form
/// picks from, instead of names typed by hand (projects have their own
/// page), and the maintenance intervals.
class ReferencePage extends StatelessWidget {
  const ReferencePage({super.key});

  static const _tabs = [
    ('People', Tables.people),
    ('Drones', Tables.aircraft),
    ('Batteries', Tables.batteries),
    ('Mission types', Tables.missionTypes),
  ];

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: _tabs.length + 1,
    child: Column(
      children: [
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final t in _tabs) Tab(text: t.$1),
            const Tab(text: 'Maintenance intervals'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              for (final t in _tabs) _ReferenceList(table: t.$2),
              const IntervalsTab(),
            ],
          ),
        ),
      ],
    ),
  );
}

const personRoles = [
  'pilot',
  'spotter',
  'technician',
  'signatory',
  'admin',
  'viewer',
];

/// A viewer's key reads everything and changes nothing.
String roleLabel(String role) => role == 'viewer' ? 'viewer (read only)' : role;

class _ReferenceList extends StatelessWidget {
  const _ReferenceList({required this.table});
  final TableDef table;

  /// Columns picked with chips instead of typed: roles, a drone's usage
  /// and a battery's drones.
  static const _chipColumns = {'roles', 'usage', 'aircraft_ids'};

  /// A drone's weather limits, typed as numbers (see WeatherLimits).
  static const _limitLabels = {
    'max_wind_ms': 'Max wind m/s (weather check, empty: 10)',
    'max_gust_ms': 'Max gusts m/s (weather check, empty: 12)',
  };

  /// Text columns shown under the name, e.g. model and serial for drones.
  List<String> get _details => [
    for (final c in table.columns)
      if (c.type == ColType.text &&
          c.name != 'name' &&
          c.name != 'usage' &&
          c.name != 'aircraft_ids' &&
          !_limitLabels.containsKey(c.name))
        c.name,
  ];

  /// "Cargo, Inspection" for a drone, "Drones 18, 24" for a battery.
  String? _chipDetail(DbRow r, Map<String, String> drones) {
    if (table == Tables.aircraft) {
      return DroneUsage.of(r['usage'] as String?)
          .map((u) => u.label)
          .join(', ');
    }
    if (table == Tables.batteries) {
      final ids = idList(r['aircraft_ids'] as String?);
      if (ids.isEmpty) return 'Any drone';
      return 'Drones ${[for (final id in ids) drones[id] ?? '?'].join(', ')}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    return Scaffold(
      floatingActionButton: AddButton(
        child: FloatingActionButton.small(
          tooltip: 'Add',
          onPressed: () => _edit(context, null),
          child: const Icon(Icons.add),
        ),
      ),
      body: table == Tables.people && services.isAdmin
          ? _KeyStatusLoader(
              builder: (keys, refresh) => _list(context, keys, refresh),
            )
          : _list(context, null, null),
    );
  }

  /// The list; for People seen by the admin, [keys] tells per person
  /// whether they have an access key and when they last signed in with it
  /// (null while loading, offline, or without Firebase).
  Widget _list(BuildContext context, _KeyState? keys, VoidCallback? refresh) {
    final services = Services.of(context);
    final db = services.db;
    return DbBuilder(
      builder: (context) {
        final rows = db.rows(table, orderBy: 'name COLLATE NOCASE');
        final drones = services.logbook.names(Tables.aircraft);
        if (rows.isEmpty) {
          return const Center(child: Text('Nothing here yet'));
        }
        final details = [
          for (final r in rows)
            [
              for (final d in _details)
                if ((r[d] as String? ?? '').isNotEmpty) r[d],
              ?_chipDetail(r, drones),
            ].join(' · '),
        ];
        return ListView(
          children: [
            if (keys != null)
              _KeySummary(
                keys: keys,
                people: [
                  for (final r in rows)
                    if (r['active'] != 0) r['id'] as String,
                ],
                refresh: refresh!,
              ),
            for (final (i, r) in rows.indexed)
              ListTile(
                title: Text(r['name'] as String? ?? ''),
                subtitle: keys == null
                    ? Text(details[i])
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (details[i].isNotEmpty) Text(details[i]),
                          _KeyLine(state: keys, personId: r['id'] as String),
                        ],
                      ),
                trailing: r['active'] == 0 ? const Text('inactive') : null,
                onTap: services.canChange(r) ? () => _edit(context, r) : null,
              ),
          ],
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, DbRow? row) async {
    final services = Services.of(context);
    final values = <String, Object?>{...?row};
    values['active'] ??= 1;
    final controllers = {
      for (final c in table.columns)
        if (c.type == ColType.text && !_chipColumns.contains(c.name))
          c.name: TextEditingController(text: values[c.name] as String?),
    };
    // Drones a battery can be put in.
    final drones = services.logbook.names(Tables.aircraft, activeOnly: true);
    final action = await showDialog<_Action>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final roles = ((values['roles'] as String?) ?? '')
              .split(',')
              .map((r) => r.trim())
              .where((r) => r.isNotEmpty)
              .toSet();
          final active = SwitchListTile(
            key: const Key('reference-active'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Active'),
            value: values['active'] == 1,
            onChanged: (on) => setState(() => values['active'] = on ? 1 : 0),
          );
          return AlertDialog(
            // Scrolls with the keyboard open, so nothing is hidden under it.
            scrollable: true,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            title: Text(row == null ? 'Add' : 'Edit'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in controllers.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextField(
                        controller: e.value,
                        autofocus: e.key == 'name' && row == null,
                        textInputAction: TextInputAction.next,
                        keyboardType: _limitLabels.containsKey(e.key)
                            ? const TextInputType.numberWithOptions(
                                decimal: true,
                              )
                            : null,
                        decoration: InputDecoration(
                          labelText:
                              _limitLabels[e.key] ?? e.key.replaceAll('_', ' '),
                        ),
                      ),
                    ),
                    // Right under the name: in view while typing it.
                    if (e.key == 'name') active,
                  ],
                  if (table == Tables.people) ...[
                    const SizedBox(height: 12),
                    _ChipsLabel('Roles'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final role in personRoles)
                          FilterChip(
                            key: Key('role-$role'),
                            label: Text(roleLabel(role)),
                            selected: roles.contains(role),
                            onSelected: (on) => setState(() {
                              on ? roles.add(role) : roles.remove(role);
                              values['roles'] = personRoles
                                  .where(roles.contains)
                                  .join(',');
                            }),
                          ),
                      ],
                    ),
                  ],
                  if (table == Tables.aircraft) ...[
                    const SizedBox(height: 12),
                    _ChipsLabel('Used for'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final u in DroneUsage.values)
                          FilterChip(
                            key: Key('usage-${u.name}'),
                            label: Text(u.label),
                            selected: DroneUsage.of(values['usage'] as String?)
                                .contains(u),
                            onSelected: (on) => setState(() {
                              final now = DroneUsage.of(
                                values['usage'] as String?,
                              );
                              on ? now.add(u) : now.remove(u);
                              // At least one; none would read as both.
                              if (now.isNotEmpty) {
                                values['usage'] = DroneUsage.format(now);
                              }
                            }),
                          ),
                      ],
                    ),
                  ],
                  if (table == Tables.batteries) ...[
                    const SizedBox(height: 12),
                    _ChipsLabel('Drones (none picked: fits any drone)'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final d in {
                          ...drones,
                          // A drone made inactive stays visible here.
                          for (final id in idList(
                            values['aircraft_ids'] as String?,
                          ))
                            if (!drones.containsKey(id))
                              id:
                                  services.logbook.names(Tables.aircraft)[id] ??
                                  '?',
                        }.entries)
                          FilterChip(
                            key: Key('battery-drone-${d.value}'),
                            label: Text(d.value),
                            selected: idList(values['aircraft_ids'] as String?)
                                .contains(d.key),
                            onSelected: (on) => setState(() {
                              final ids = idList(
                                values['aircraft_ids'] as String?,
                              );
                              on ? ids.add(d.key) : ids.remove(d.key);
                              values['aircraft_ids'] = ids.join(',');
                            }),
                          ),
                      ],
                    ),
                  ],
                  if (row != null &&
                      table == Tables.people &&
                      services.isAdmin) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        key: const Key('person-link'),
                        onPressed: () => _showPersonKey(context, row),
                        icon: const Icon(Icons.key),
                        label: const Text('Personal access key'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              if (row != null && services.canChange(row))
                TextButton(
                  key: const Key('delete-reference'),
                  onPressed: () async {
                    if (await _confirmDelete(context, row) && context.mounted) {
                      Navigator.pop(context, _Action.delete);
                    }
                  },
                  child: const Text('Delete'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, _Action.save),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (action == _Action.save && controllers['name']!.text.trim().isNotEmpty) {
      services.db.save(table, {
        ...values,
        for (final e in controllers.entries) e.key: e.value.text.trim(),
      });
      services.sync.sync();
    } else if (action == _Action.delete) {
      services.db.delete(table, row!['id'] as String);
      services.sync.sync();
    }
    // The controllers are not disposed: the dialog still shows them while
    // it fades out, and they hold nothing but a few words of text.
  }
}

enum _Action { save, delete }

class _ChipsLabel extends StatelessWidget {
  const _ChipsLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: Theme.of(context).textTheme.labelLarge),
    ),
  );
}

Future<bool> _confirmDelete(BuildContext context, DbRow row) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(
          'Delete ${row['name']}? It disappears from this list and from the '
          'pickers; old flights and checks keep showing the name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ==
    true;

/// The admin gets a person's own access key: with it in Settings, that
/// person gets in (only while active in People) and can change and delete
/// what they added; a viewer only reads. New key turns the old one off.
Future<void> _showPersonKey(BuildContext context, DbRow person) async {
  final sync = Services.of(context).sync;
  final id = person['id'] as String;
  Future<String> make({bool renew = false}) async {
    try {
      final key = await sync.personKey(id, renew: renew);
      await Clipboard.setData(ClipboardData(text: key));
      return key;
    } catch (e) {
      return 'Could not make the key: $e';
    }
  }

  var text = await make();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text('Access key for ${person['name']}'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Copied. Send it only to this person: they paste it in '
                'Settings > Access key. It works only while the person is '
                'active here; New key turns this one off.',
              ),
              const SizedBox(height: 12),
              SelectableText(text, key: const Key('person-link-text')),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('person-key-renew'),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  content: Text(
                    'Make a new key for ${person['name']}? The old key stops '
                    'working at once; they need to paste the new one.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('New key'),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
              final key = await make(renew: true);
              setState(() => text = key);
            },
            child: const Text('New key'),
          ),
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}

/// The admin's view of everyone's access keys, loaded from the server
/// when People opens (and with the refresh button).
class _KeyState {
  const _KeyState({this.keys, this.error, this.loading = false});

  /// Per person id; a person missing here has no key.
  final Map<String, KeyStatus>? keys;
  final String? error;
  final bool loading;
}

class _KeyStatusLoader extends StatefulWidget {
  const _KeyStatusLoader({required this.builder});

  final Widget Function(_KeyState? keys, VoidCallback refresh) builder;

  @override
  State<_KeyStatusLoader> createState() => _KeyStatusLoaderState();
}

class _KeyStatusLoaderState extends State<_KeyStatusLoader> {
  _KeyState? _state = const _KeyState(loading: true);

  @override
  void initState() {
    super.initState();
    // After the first frame: Services is looked up from the context.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final sync = Services.of(context).sync;
    setState(() => _state = _KeyState(keys: _state?.keys, loading: true));
    _KeyState? next;
    try {
      final keys = await sync.keyStatuses();
      // Without Firebase nothing is known: no key lines at all.
      next = keys == null ? null : _KeyState(keys: keys);
    } catch (e) {
      next = _KeyState(error: '$e');
    }
    if (mounted) setState(() => _state = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(_state, _load);
}

final _seenFormat = DateFormat('dd.MM.yyyy HH:mm');

/// "Signed in 15.11.2026 08:20 · Windows 1.10.0", "Has a key, not signed
/// in yet" or "No access key", under a person's name.
class _KeyLine extends StatelessWidget {
  const _KeyLine({required this.state, required this.personId});

  final _KeyState state;
  final String personId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keys = state.keys;
    if (keys == null) return const SizedBox.shrink();
    final k = keys[personId];
    final (IconData icon, Color color, String text) = switch (k) {
      null => (Icons.key_off_outlined, scheme.outline, 'No access key'),
      KeyStatus(lastSeen: final seen?) => (
        Icons.check_circle,
        keyGreen(context),
        'Signed in ${_seenFormat.format(seen.toLocal())}'
            '${(k.app ?? '').isEmpty ? '' : ' · ${_shortApp(k.app!)}'}',
      ),
      _ => (
        Icons.key,
        keyAmber(context),
        'Has a key${k.madeAt == null ? '' : ' (made ${DateFormat('dd.MM.yyyy').format(k.madeAt!.toLocal())})'}'
            ', not signed in yet',
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              key: Key('key-status-$personId'),
              style: TextStyle(color: color, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Windows 1.10.0+140" without the build number.
String _shortApp(String app) => app.replaceFirst(RegExp(r'\+\d+$'), '');

Color keyGreen(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF8BD17C)
    : const Color(0xFF2E7D32);

Color keyAmber(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFFE8B84A)
    : const Color(0xFF8A5A00);

/// Above the People list: how many active people signed in, have a key
/// but did not sign in yet, and have none; and the refresh button.
class _KeySummary extends StatelessWidget {
  const _KeySummary({
    required this.keys,
    required this.people,
    required this.refresh,
  });

  final _KeyState keys;
  final List<String> people;
  final VoidCallback refresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final k = keys.keys;
    final Widget text;
    if (keys.error != null) {
      text = Text(
        'Access keys: could not load (${keys.error})',
        style: TextStyle(color: theme.colorScheme.error),
      );
    } else if (k == null) {
      text = const Text('Access keys: loading…');
    } else {
      final signedIn = people.where((p) => k[p]?.signedIn ?? false).length;
      final waiting = people
          .where((p) => k[p] != null && !k[p]!.signedIn)
          .length;
      final none = people.length - signedIn - waiting;
      text = Wrap(
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Access keys (active people):',
            style: theme.textTheme.labelLarge,
          ),
          _count(Icons.check_circle, keyGreen(context), '$signedIn signed in'),
          _count(Icons.key, keyAmber(context), '$waiting not signed in yet'),
          _count(
            Icons.key_off_outlined,
            theme.colorScheme.outline,
            '$none no key',
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 4, 4),
      child: Row(
        children: [
          Expanded(child: text),
          IconButton(
            key: const Key('key-status-refresh'),
            tooltip: 'Refresh key status',
            onPressed: keys.loading ? null : refresh,
            icon: keys.loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _count(IconData icon, Color color, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 4),
      Text(text),
    ],
  );
}
