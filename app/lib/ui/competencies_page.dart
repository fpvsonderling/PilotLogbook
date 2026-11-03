import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/competencies.dart';
import '../data/local_db.dart';
import '../data/schema.dart';
import 'due_colors.dart';
import 'links.dart';
import 'services.dart';

Urgency urgencyOfCompetency(CompetencyStatus s) => switch (s) {
  CompetencyStatus.valid => Urgency.ok,
  CompetencyStatus.expiring => Urgency.soon,
  CompetencyStatus.expired => Urgency.over,
};

/// Pilots' licences, trainings, medicals and insurance. A pilot with their
/// own key sees and adds only their own; the admin sees everyone's, changes
/// them and marks them verified.
class CompetenciesPage extends StatelessWidget {
  const CompetenciesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    return DbBuilder(
      builder: (context) {
        final sync = services.sync;
        final admin = services.isAdmin;
        final me = sync.me;
        final canAdd = services.canAdd && (admin || me != null);
        final log = CompetencyLog(services.db);
        final today = log.today();
        final people = services.logbook.names(Tables.people);
        final theme = Theme.of(context);
        final all = log.all(personId: admin ? null : me);
        // The admin: everyone with a competency and every active pilot.
        final byPerson = <String, List<Competency>>{
          if (admin)
            for (final id in services.logbook.peopleWithRole('pilot').keys)
              id: [],
          if (!admin && me != null) me: [],
        };
        for (final c in all) {
          byPerson.putIfAbsent(c.personId ?? '', () => []).add(c);
        }
        final order = byPerson.keys.toList()
          ..sort(
            (a, b) => (people[a] ?? '').toLowerCase().compareTo(
              (people[b] ?? '').toLowerCase(),
            ),
          );
        return Scaffold(
          floatingActionButton: canAdd
              ? FloatingActionButton.extended(
                  key: const Key('add-competency'),
                  onPressed: () => editCompetency(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Add competency'),
                )
              : null,
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Text(
                admin
                    ? 'Everyone\'s competencies. Only each pilot and the '
                          'admins see them.'
                    : 'Your competencies. Only you and the admins see them.',
                style: theme.textTheme.bodySmall,
              ),
              if (!admin && me == null)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    'Competencies need your personal access key: ask the '
                    'admin for it and paste it in Settings.',
                  ),
                ),
              for (final id in order) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 20, bottom: 8),
                  child: Text(
                    people[id] ?? 'Unknown person',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (byPerson[id]!.isEmpty)
                  Text(
                    'Nothing added yet',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                for (final c in byPerson[id]!)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CompetencyCard(competency: c, today: today),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _CompetencyCard extends StatelessWidget {
  const _CompetencyCard({required this.competency, required this.today});
  final Competency competency;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final services = Services.of(context);
    final c = competency;
    final canChange =
        !services.sync.readOnly &&
        (services.isAdmin || c.personId == services.sync.me);
    final status = c.status(today);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return Card(
      key: Key('competency-${c.type}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: canChange ? () => editCompetency(context, row: c.row) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      c.type.isEmpty ? 'Competency' : c.type,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (c.verified) ...[
                    Icon(
                      Icons.verified,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text('Verified', style: muted),
                    const SizedBox(width: 8),
                  ],
                  UrgencyPill(c.describe(today), urgencyOfCompetency(status)),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (c.number.isNotEmpty) 'No. ${c.number}',
                  if (c.issuedOn.isNotEmpty) 'issued ${_day(c.issuedOn)}',
                  if (c.expiresOn.isNotEmpty) 'valid to ${_day(c.expiresOn)}',
                ].join(' · '),
                style: muted,
              ),
              if (c.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(c.notes, style: muted),
                ),
              if (c.url.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => openLink(context, c.url),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open document'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "2027-03-31" -> "31.03.2027"
String _day(String d) {
  final p = d.split('-');
  return p.length == 3 ? '${p[2]}.${p[1]}.${p[0]}' : d;
}

/// Add a competency or change [row]. A pilot adds only their own; the admin
/// picks the person and may mark it verified.
Future<void> editCompetency(BuildContext context, {DbRow? row}) async {
  final services = Services.of(context);
  final admin = services.isAdmin;
  final values = <String, Object?>{...?row};
  values['person_id'] ??= admin ? null : services.sync.me;
  final wasVerified = values['verified'] == 1;
  final text = {
    for (final k in [
      'type',
      'number',
      'issued_on',
      'expires_on',
      'url',
      'notes',
    ])
      k: TextEditingController(text: values[k] as String?),
  };
  final people = {
    ...services.logbook.peopleWithRole('pilot'),
    if (values['person_id'] != null)
      values['person_id'] as String:
          services.logbook.names(Tables.people)[values['person_id']] ?? '?',
  };
  final form = GlobalKey<FormState>();
  String? date(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    return DateTime.tryParse(t) == null || t.length != 10
        ? 'Date as yyyy-MM-dd'
        : null;
  }

  final action = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Widget dateField(String key, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            key: Key('competency-$key'),
            controller: text[key],
            validator: date,
            decoration: InputDecoration(
              labelText: label,
              hintText: 'yyyy-MM-dd',
              suffixIcon: IconButton(
                tooltip: 'Pick a date',
                icon: const Icon(Icons.calendar_today),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate:
                        DateTime.tryParse(text[key]!.text) ?? DateTime.now(),
                    firstDate: DateTime(1990),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    text[key]!.text = DateFormat('yyyy-MM-dd').format(picked);
                  }
                },
              ),
            ),
          ),
        );
        return AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: Text(row == null ? 'Add competency' : 'Competency'),
          content: SizedBox(
            width: 440,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (admin)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DropdownButtonFormField<String>(
                        key: const Key('competency-person'),
                        initialValue: values['person_id'] as String?,
                        decoration: const InputDecoration(labelText: 'Person'),
                        items: [
                          for (final e in people.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                        onChanged: (id) => values['person_id'] = id,
                        validator: (v) => v == null ? 'Required' : null,
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final t in competencyTypes)
                        ChoiceChip(
                          label: Text(t),
                          selected: text['type']!.text == t,
                          onSelected: (_) =>
                              setState(() => text['type']!.text = t),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const Key('competency-type'),
                    controller: text['type'],
                    decoration: const InputDecoration(labelText: 'Type'),
                    onChanged: (_) => setState(() {}),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('competency-number'),
                    controller: text['number'],
                    decoration: const InputDecoration(
                      labelText: 'Number (certificate, policy...)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  dateField('issued_on', 'Issued on'),
                  dateField('expires_on', 'Valid to (empty: no expiry)'),
                  TextFormField(
                    key: const Key('competency-url'),
                    controller: text['url'],
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Link to the document (Google Drive)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: text['notes'],
                    decoration: const InputDecoration(labelText: 'Notes'),
                    maxLines: 2,
                  ),
                  if (admin)
                    SwitchListTile(
                      key: const Key('competency-verified'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Verified'),
                      subtitle: const Text('I checked the document'),
                      value: values['verified'] == 1,
                      onChanged: (on) =>
                          setState(() => values['verified'] = on ? 1 : null),
                    )
                  else if (wasVerified)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Saving a change takes the Verified mark off until '
                        'the admin checks it again.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (row != null)
              TextButton(
                key: const Key('delete-competency'),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      content: const Text('Delete this competency?'),
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
              key: const Key('save-competency'),
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, 'save');
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
  if (action == 'save') {
    final verified = admin ? values['verified'] == 1 : false;
    services.db.save(Tables.competencies, {
      ...values,
      for (final e in text.entries) e.key: e.value.text.trim(),
      'verified': verified ? 1 : null,
      'verified_by': verified
          ? (wasVerified ? values['verified_by'] : services.sync.me)
          : null,
    });
    services.sync.sync();
  } else if (action == 'delete' && row != null) {
    services.db.delete(Tables.competencies, row['id'] as String);
    services.sync.sync();
  }
}
