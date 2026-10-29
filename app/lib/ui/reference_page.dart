import 'package:flutter/material.dart';

import '../data/local_db.dart';
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

const personRoles = ['pilot', 'spotter', 'technician', 'signatory', 'admin'];

class _ReferenceList extends StatelessWidget {
  const _ReferenceList({required this.table});
  final TableDef table;

  /// Text columns shown under the name, e.g. model and serial for drones.
  List<String> get _details => [
    for (final c in table.columns)
      if (c.type == ColType.text && c.name != 'name') c.name,
  ];

  @override
  Widget build(BuildContext context) {
    final db = Services.of(context).db;
    return Scaffold(
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Add',
        onPressed: () => _edit(context, null),
        child: const Icon(Icons.add),
      ),
      body: DbBuilder(
        builder: (context) {
          final rows = db.rows(table, orderBy: 'name COLLATE NOCASE');
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
                    ].join(' · '),
                  ),
                  trailing: r['active'] == 0 ? const Text('inactive') : null,
                  onTap: () => _edit(context, r),
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
        if (c.type == ColType.text && c.name != 'roles')
          c.name: TextEditingController(text: values[c.name] as String?),
    };
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final roles = ((values['roles'] as String?) ?? '')
              .split(',')
              .map((r) => r.trim())
              .where((r) => r.isNotEmpty)
              .toSet();
          return AlertDialog(
            title: Text(row == null ? 'Add' : 'Edit'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in controllers.entries)
                    TextField(
                      controller: e.value,
                      autofocus: e.key == 'name',
                      decoration: InputDecoration(
                        labelText: e.key.replaceAll('_', ' '),
                      ),
                    ),
                  if (table == Tables.people) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final role in personRoles)
                          FilterChip(
                            label: Text(role),
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
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: values['active'] == 1,
                    onChanged: (on) =>
                        setState(() => values['active'] = on ? 1 : 0),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (saved == true && controllers['name']!.text.trim().isNotEmpty) {
      services.db.save(table, {
        ...values,
        for (final e in controllers.entries) e.key: e.value.text.trim(),
      });
      services.sync.sync();
    }
    for (final c in controllers.values) {
      c.dispose();
    }
  }
}
