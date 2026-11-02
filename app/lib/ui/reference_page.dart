import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import 'services.dart';

/// People, projects, drones, batteries and mission types: the lists every
/// form picks from, instead of names typed by hand.
class ReferencePage extends StatelessWidget {
  const ReferencePage({super.key});

  static const _tabs = [
    ('People', Tables.people),
    ('Projects', Tables.projects),
    ('Drones', Tables.aircraft),
    ('Batteries', Tables.batteries),
    ('Mission types', Tables.missionTypes),
  ];

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: _tabs.length,
    child: Column(
      children: [
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in _tabs) Tab(text: t.$1)],
        ),
        Expanded(
          child: TabBarView(
            children: [for (final t in _tabs) _ReferenceList(table: t.$2)],
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

  /// Text columns shown under the name, e.g. model and serial for drones.
  List<String> get _details => [
    for (final c in table.columns)
      if (c.type == ColType.text &&
          c.name != 'name' &&
          c.name != 'usage' &&
          c.name != 'aircraft_ids')
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
    final db = services.db;
    return Scaffold(
      floatingActionButton: AddButton(
        child: FloatingActionButton.small(
          tooltip: 'Add',
          onPressed: () => _edit(context, null),
          child: const Icon(Icons.add),
        ),
      ),
      body: DbBuilder(
        builder: (context) {
          final rows = db.rows(table, orderBy: 'name COLLATE NOCASE');
          final drones = services.logbook.names(Tables.aircraft);
          if (rows.isEmpty) {
            return const Center(child: Text('Nothing here yet'));
          }
          return ListView(
            children: [
              for (final r in rows)
                ListTile(
                  title: Text(r['name'] as String? ?? ''),
                  subtitle: Text(
                    [
                      for (final d in _details)
                        if ((r[d] as String? ?? '').isNotEmpty) r[d],
                      ?_chipDetail(r, drones),
                    ].join(' · '),
                  ),
                  trailing: r['active'] == 0 ? const Text('inactive') : null,
                  onTap: services.canChange(r) ? () => _edit(context, r) : null,
                ),
            ],
          );
        },
      ),
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
                        decoration: InputDecoration(
                          labelText: e.key.replaceAll('_', ' '),
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
