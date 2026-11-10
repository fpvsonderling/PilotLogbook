import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/projects.dart';
import '../data/schema.dart';
import 'links.dart';
import 'maintenance_page.dart' show formatHours;
import 'services.dart';

/// Projects (wind farms): client, country, where they are with buttons to
/// Google Maps and the zone map, and the flying there. Only the admin adds
/// and changes them; every flight picks its project.
class ProjectsPage extends StatelessWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    return Scaffold(
      // Shown once a sync says this is the admin's key.
      floatingActionButton: ListenableBuilder(
        listenable: services.sync,
        builder: (context, _) => services.isAdmin
            ? FloatingActionButton.extended(
                key: const Key('add-project'),
                onPressed: () => editProject(context),
                icon: const Icon(Icons.add_location_alt),
                label: const Text('New project'),
              )
            : const SizedBox.shrink(),
      ),
      body: DbBuilder(
        builder: (context) {
          final rows = services.db.rows(
            Tables.projects,
            orderBy: 'COALESCE(active, 1) DESC, name COLLATE NOCASE',
          );
          final stats = {
            for (final s in services.logbook.projectStats()) s.id: s,
          };
          if (rows.isEmpty) {
            return Center(
              child: Text(
                services.isAdmin
                    ? 'No projects yet: add the first one'
                    : 'No projects yet: the admin adds them',
              ),
            );
          }
          return LayoutBuilder(
            builder: (context, box) {
              // One column on a phone, cards of about 380 wide on a PC.
              final columns = (box.maxWidth / 380).floor().clamp(1, 4);
              const gap = 12.0;
              final width = (box.maxWidth - 32 - gap * (columns - 1)) / columns;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                child: Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final r in rows)
                      SizedBox(
                        width: width,
                        child: _ProjectCard(
                          project: Project(r),
                          stat: stats[r['id']],
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.stat});
  final Project project;
  final FlightStat? stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = Services.of(context);
    final p = project;
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final points = p.points;
    final where = [p.client, p.country].where((t) => t.isNotEmpty).join(' · ');
    return Card(
      key: Key('project-${p.name}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: services.isAdmin ? () => editProject(context, row: p.row) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(p.name, style: theme.textTheme.titleMedium),
                  ),
                  if (!p.active) Text('inactive', style: muted),
                ],
              ),
              if (where.isNotEmpty) Text(where, style: muted),
              const SizedBox(height: 6),
              Text(
                stat == null
                    ? 'No flights yet'
                    : '${stat!.flights} flights · '
                          '${formatHours(stat!.seconds)} h',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (points.isNotEmpty)
                Text(
                  points.length == 1
                      ? points.first.text
                      : '${points.length} points',
                  style: muted,
                ),
              if (p.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    p.notes,
                    style: muted,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Wrap(
                spacing: 4,
                children: [
                  if (p.mapsUrl.isNotEmpty)
                    TextButton.icon(
                      key: Key('maps-${p.name}'),
                      onPressed: () => openLink(context, p.mapsUrl),
                      icon: const Icon(Icons.map_outlined, size: 18),
                      label: const Text('Google Maps'),
                    ),
                  if (p.zoneMapUrl.isNotEmpty)
                    TextButton.icon(
                      key: Key('zones-${p.name}'),
                      onPressed: () => openLink(context, p.zoneMapUrl),
                      icon: const Icon(Icons.layers_outlined, size: 18),
                      label: const Text('Zone map'),
                    ),
                  if (points.length > 1)
                    TextButton.icon(
                      onPressed: () => _showPoints(context, p),
                      icon: const Icon(Icons.place_outlined, size: 18),
                      label: const Text('Points'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every point of a project (e.g. each turbine) with its own map button.
Future<void> _showPoints(BuildContext context, Project p) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    title: Text(p.name),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, pt) in p.points.indexed)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(pt.label.isEmpty ? 'Point ${i + 1}' : pt.label),
              subtitle: Text(pt.text),
              trailing: IconButton(
                tooltip: 'Google Maps',
                icon: const Icon(Icons.map_outlined),
                onPressed: () => openLink(context, pt.mapsUrl),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('Close'),
      ),
    ],
  ),
);

/// The admin adds a project or changes [row].
Future<void> editProject(BuildContext context, {DbRow? row}) async {
  final services = Services.of(context);
  final values = <String, Object?>{...?row};
  values['active'] ??= 1;
  const fields = [
    ('name', 'Name'),
    ('client', 'Client'),
    ('country', 'Country'),
    ('coordinates', 'Coordinates'),
    ('maps_url', 'Own Google Maps link (empty: from the coordinates)'),
    ('zone_map_url', 'Zone map link (the country\'s drone zones)'),
    ('notes', 'Notes'),
  ];
  final text = {
    for (final (k, _) in fields)
      k: TextEditingController(text: values[k] as String?),
  };
  final form = GlobalKey<FormState>();
  final action = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text(row == null ? 'New project' : 'Project'),
        content: SizedBox(
          width: 480,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (k, label) in fields) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      key: Key('project-$k'),
                      controller: text[k],
                      autofocus: k == 'name' && row == null,
                      minLines: k == 'coordinates' || k == 'notes' ? 2 : 1,
                      maxLines: k == 'coordinates' || k == 'notes' ? 6 : 1,
                      keyboardType: k.endsWith('url')
                          ? TextInputType.url
                          : null,
                      decoration: InputDecoration(
                        labelText: label,
                        helperText: k == 'coordinates'
                            ? 'One per line: 54.1234, 2.5678 or '
                                  'T01: 54.1234, 2.5678, or paste a '
                                  'Google Maps link'
                            : null,
                        helperMaxLines: 3,
                      ),
                      onChanged: k == 'coordinates'
                          ? (_) => setState(() {})
                          : null,
                      validator: (v) {
                        if (k == 'name' && (v ?? '').trim().isEmpty) {
                          return 'Required';
                        }
                        if (k == 'coordinates') {
                          final bad = parseCoordinates(v).bad;
                          if (bad.isNotEmpty) {
                            return 'Not coordinates: ${bad.first}'
                                '${bad.first.contains('goo.gl') ? ' (short '
                                          'links cannot be read: open it and copy '
                                          'the long link or the numbers)' : ''}';
                          }
                        }
                        return null;
                      },
                    ),
                  ),
                  if (k == 'name')
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active'),
                      value: values['active'] == 1,
                      onChanged: (on) =>
                          setState(() => values['active'] = on ? 1 : 0),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (row != null)
            TextButton(
              key: const Key('delete-project'),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    content: Text(
                      'Delete ${row['name']}? Its flights keep the name.',
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
                );
                if (ok == true && context.mounted) {
                  Navigator.pop(context, 'delete');
                }
              },
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('save-project'),
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, 'save');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (action == 'save') {
    // Links pasted as coordinates are kept as plain numbers.
    final coords = text['coordinates']!.text;
    final points = parseCoordinates(coords).points;
    services.db.save(Tables.projects, {
      ...values,
      for (final e in text.entries) e.key: e.value.text.trim(),
      'coordinates': [
        for (final p in points)
          p.label.isEmpty ? p.text : '${p.label}: ${p.text}',
      ].join('\n'),
    });
    services.sync.sync();
  } else if (action == 'delete' && row != null) {
    services.db.delete(Tables.projects, row['id'] as String);
    services.sync.sync();
  }
}
