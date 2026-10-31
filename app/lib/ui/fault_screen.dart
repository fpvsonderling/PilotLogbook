import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import 'fault_widgets.dart';
import 'services.dart';

void openFault(BuildContext context, String faultId) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => FaultScreen(faultId)));

/// Whether this device may test and sign off: the admin link, or the own
/// link of a person with the signatory or admin role.
bool canSignOff(Services services) {
  if (services.isAdmin) return true;
  final me = services.sync.me;
  if (me == null) return false;
  final logbook = services.logbook;
  return logbook.peopleWithRole('signatory').containsKey(me) ||
      logbook.peopleWithRole('admin').containsKey(me);
}

/// One fault from report to sign-off, oldest step first.
class FaultScreen extends StatelessWidget {
  const FaultScreen(this.faultId, {super.key});
  final String faultId;

  @override
  Widget build(BuildContext context) {
    return DbBuilder(
      builder: (context) {
        final services = Services.of(context);
        final logbook = services.logbook;
        final c = logbook.faultCase(faultId);
        if (c == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This fault was deleted')),
          );
        }
        final aircraft = logbook.names(Tables.aircraft);
        final batteries = logbook.names(Tables.batteries);
        final people = logbook.names(Tables.people);
        final theme = Theme.of(context);
        final steps = <(String, Widget)>[
          for (final r in c.repairs)
            (
              FaultCase.repairTime(r),
              _RepairCard(fault: c, repair: r, people: people),
            ),
          for (final s in c.signoffs)
            (
              s['tested_at'] as String? ?? '',
              _SignoffCard(fault: c, signoff: s, people: people),
            ),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        final open = c.status != FaultStatus.closed;
        return Scaffold(
          appBar: AppBar(title: Text(faultSubject(c, aircraft, batteries))),
          bottomNavigationBar: open
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        if (canSignOff(services))
                          OutlinedButton.icon(
                            onPressed: () =>
                                showFaultForm(context, SignoffForm(fault: c)),
                            icon: const Icon(Icons.verified_outlined),
                            label: const Text('Test and sign off'),
                          ),
                        FilledButton.icon(
                          onPressed: () =>
                              showFaultForm(context, RepairForm(fault: c)),
                          icon: const Icon(Icons.build),
                          label: const Text('Record repair'),
                        ),
                      ],
                    ),
                  ),
                )
              : null,
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      Pill(
                        severityTitles[c.severity] ?? 'Class ?',
                        severityColors(context, c.severity),
                        icon: c.grounded ? Icons.block : null,
                      ),
                      Pill(
                        statusTitles[c.status]!,
                        statusColors(context, c.status),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _StepCard(
                    icon: Icons.report_problem_outlined,
                    title: 'Report',
                    when: c.reportedAt,
                    who: personName(people, c.fault['discovered_by_id']),
                    onEdit: services.canChange(c.fault)
                        ? () =>
                              showFaultForm(context, FaultReportForm(fault: c))
                        : null,
                    children: [
                      Text(
                        c.fault['description'] as String? ?? '',
                        style: theme.textTheme.bodyLarge,
                      ),
                      _Photos(c.photosOf()),
                    ],
                  ),
                  for (final (_, w) in steps) w,
                  if (c.status == FaultStatus.repaired)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        canSignOff(services)
                            ? 'Repaired. Test it and sign off to close.'
                            : 'Repaired. Waiting for a signatory to test '
                                  'and sign off.',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.icon,
    required this.title,
    required this.when,
    required this.who,
    required this.children,
    this.onEdit,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String when;
  final String who;
  final List<Widget> children;
  final VoidCallback? onEdit;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(title, style: theme.textTheme.titleMedium),
                          if (badge != null) ...[
                            const SizedBox(width: 8),
                            badge!,
                          ],
                        ],
                      ),
                      Text(
                        [when, who].where((t) => t.isNotEmpty).join(' · '),
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (onEdit != null)
                  IconButton(
                    tooltip: 'Edit',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A label and its text, left out when the text is empty.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    final text = value as String? ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: text),
          ],
        ),
      ),
    );
  }
}

class _Photos extends StatelessWidget {
  const _Photos(this.photos);
  final List<DbRow> photos;

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final p in photos)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: () => showPhoto(
                  context,
                  FaultPhoto(p, size: 2000, fit: BoxFit.contain),
                ),
                child: FaultPhoto(p, size: 120),
              ),
            ),
        ],
      ),
    );
  }
}

class _RepairCard extends StatelessWidget {
  const _RepairCard({
    required this.fault,
    required this.repair,
    required this.people,
  });

  final FaultCase fault;
  final DbRow repair;
  final Map<String, String> people;

  @override
  Widget build(BuildContext context) {
    final r = repair;
    final started = r['started_at'] as String? ?? '';
    final finished = r['finished_at'] as String? ?? '';
    return _StepCard(
      icon: Icons.build,
      title: 'Repair',
      when: [started, finished].where((t) => t.isNotEmpty).join(' – '),
      who: r['technicians'] as String? ?? '',
      onEdit: Services.of(context).canChange(r)
          ? () => showFaultForm(context, RepairForm(fault: fault, repair: r))
          : null,
      children: [
        _Field('Work performed', r['work_performed']),
        _Field('Materials used', r['materials_used']),
        _Field('Notes', r['notes']),
        _Photos(fault.photosOf(r['id'] as String)),
      ],
    );
  }
}

class _SignoffCard extends StatelessWidget {
  const _SignoffCard({
    required this.fault,
    required this.signoff,
    required this.people,
  });

  final FaultCase fault;
  final DbRow signoff;
  final Map<String, String> people;

  @override
  Widget build(BuildContext context) {
    final s = signoff;
    final passed = s['result'] == 'pass';
    return _StepCard(
      icon: passed ? Icons.verified : Icons.replay,
      title: 'Test and sign-off',
      badge: Pill(
        passed ? 'Passed' : 'Failed',
        statusColors(context, passed ? FaultStatus.closed : FaultStatus.open),
      ),
      when: s['tested_at'] as String? ?? '',
      who: personName(people, s['signatory_id']),
      onEdit: Services.of(context).canChange(s)
          ? () => showFaultForm(context, SignoffForm(fault: fault, signoff: s))
          : null,
      children: [_Field('Notes', s['notes'])],
    );
  }
}

// ------------------------------------------------------------------ forms

/// Saves the photos picked in a form and deletes the ones removed.
void _savePhotos(
  Services services, {
  required String faultId,
  String? repairId,
  required List<Uint8List> added,
  required Set<String> removed,
}) {
  for (final id in removed) {
    services.db.delete(Tables.faultPhotos, id);
  }
  final store = services.sync.photos;
  if (store == null) return;
  for (final b in added) {
    store.add(services.db, faultId: faultId, repairId: repairId, bytes: b);
  }
}

class FaultReportForm extends StatefulWidget {
  const FaultReportForm({super.key, this.fault});
  final FaultCase? fault;

  @override
  State<FaultReportForm> createState() => _FaultReportFormState();
}

class _FaultReportFormState extends State<FaultReportForm> {
  final _form = GlobalKey<FormState>();
  late final DbRow _v = {...?widget.fault?.fault};
  late final _at = TextEditingController(
    text: _v['reported_at'] as String? ?? faultNow(),
  );
  late final _equipment = TextEditingController(
    text: _v['equipment'] as String?,
  );
  late final _description = TextEditingController(
    text: _v['description'] as String?,
  );
  final _added = <Uint8List>[];
  final _removed = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _v['discovered_by_id'] ??= Services.of(context).sync.me;
  }

  @override
  void dispose() {
    for (final c in [_at, _equipment, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final noSubject =
        _v['aircraft_id'] == null &&
        _v['battery_id'] == null &&
        _equipment.text.trim().isEmpty;
    if (!_form.currentState!.validate() ||
        noSubject ||
        _v['severity'] == null) {
      if (noSubject || _v['severity'] == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              noSubject
                  ? 'Pick the drone, the battery or write the equipment'
                  : 'Pick the class',
            ),
          ),
        );
      }
      return;
    }
    final services = Services.of(context);
    final id = services.db.save(Tables.faults, {
      ..._v,
      'reported_at': _at.text.trim(),
      'equipment': _equipment.text.trim(),
      'description': _description.text.trim(),
    });
    _savePhotos(services, faultId: id, added: _added, removed: _removed);
    Navigator.of(context).pop();
    services.sync.sync();
  }

  Future<void> _delete() async {
    if (!await confirmDelete(context, 'fault report') || !mounted) return;
    final services = Services.of(context);
    services.db.delete(Tables.faults, _v['id'] as String);
    Navigator.of(context).pop();
    services.sync.sync();
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final logbook = services.logbook;
    final theme = Theme.of(context);
    final aircraft = logbook.names(Tables.aircraft, activeOnly: true);
    final batteries = logbook.names(Tables.batteries, activeOnly: true);
    return FormFrame(
      formKey: _form,
      title: widget.fault == null ? 'Report fault' : 'Edit fault report',
      onSave: _save,
      onDelete: widget.fault != null && services.canChange(widget.fault!.fault)
          ? _delete
          : null,
      children: [
        Text('Drone', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in aircraft.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _v['aircraft_id'] == e.key,
                onSelected: (on) =>
                    setState(() => _v['aircraft_id'] = on ? e.key : null),
              ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          initialValue: batteries.containsKey(_v['battery_id'])
              ? _v['battery_id'] as String
              : null,
          decoration: const InputDecoration(labelText: 'Battery'),
          items: [
            const DropdownMenuItem(value: null, child: Text('—')),
            for (final e in batteries.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (id) => _v['battery_id'] = id,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _equipment,
          decoration: const InputDecoration(
            labelText: 'Other equipment',
            hintText: 'GCS, radio, charger …',
          ),
        ),
        const SizedBox(height: 16),
        Text('Class', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        for (final e in severityTitles.entries)
          _SeverityTile(
            severity: e.key,
            selected: _v['severity'] == e.key,
            onTap: () => setState(() => _v['severity'] = e.key),
          ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _description,
          decoration: const InputDecoration(labelText: 'What is wrong'),
          maxLines: 4,
          minLines: 2,
          validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
        ),
        const SizedBox(height: 12),
        PhotoPicker(
          saved: widget.fault?.photosOf() ?? const [],
          added: _added,
          removed: _removed,
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: 16),
        PersonField(
          label: 'Discovered by',
          people: logbook.names(Tables.people, activeOnly: true),
          value: _v['discovered_by_id'] as String?,
          onChanged: (id) => _v['discovered_by_id'] = id,
        ),
        TimeStampField(label: 'When', controller: _at),
      ],
    );
  }
}

class _SeverityTile extends StatelessWidget {
  const _SeverityTile({
    required this.severity,
    required this.selected,
    required this.onTap,
  });

  final int severity;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = severityColors(context, severity);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? bg : theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? fg : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected ? fg : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        severityTitles[severity]!,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: selected ? fg : null,
                        ),
                      ),
                      Text(
                        severityHelp[severity]!,
                        style: TextStyle(color: selected ? fg : null),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RepairForm extends StatefulWidget {
  const RepairForm({super.key, required this.fault, this.repair});
  final FaultCase fault;
  final DbRow? repair;

  @override
  State<RepairForm> createState() => _RepairFormState();
}

class _RepairFormState extends State<RepairForm> {
  final _form = GlobalKey<FormState>();
  late final DbRow _v = {...?widget.repair};
  late final _started = TextEditingController(
    text: _v['started_at'] as String? ?? faultNow(),
  );
  late final _finished = TextEditingController(
    text: _v['finished_at'] as String? ?? faultNow(),
  );
  late final _technicians = TextEditingController(
    text: _v['technicians'] as String?,
  );
  late final _work = TextEditingController(
    text: _v['work_performed'] as String?,
  );
  late final _materials = TextEditingController(
    text: _v['materials_used'] as String?,
  );
  late final _notes = TextEditingController(text: _v['notes'] as String?);
  final _added = <Uint8List>[];
  final _removed = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = Services.of(context);
    final me = services.sync.me;
    if (widget.repair == null && _technicians.text.isEmpty && me != null) {
      _technicians.text = services.logbook.names(Tables.people)[me] ?? '';
    }
  }

  @override
  void dispose() {
    for (final c in [
      _started,
      _finished,
      _technicians,
      _work,
      _materials,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final services = Services.of(context);
    final id = services.db.save(Tables.faultRepairs, {
      ..._v,
      'fault_id': widget.fault.id,
      'started_at': _started.text.trim(),
      'finished_at': _finished.text.trim(),
      'technicians': _technicians.text.trim(),
      'work_performed': _work.text.trim(),
      'materials_used': _materials.text.trim(),
      'notes': _notes.text.trim(),
    });
    _savePhotos(
      services,
      faultId: widget.fault.id,
      repairId: id,
      added: _added,
      removed: _removed,
    );
    Navigator.of(context).pop();
    services.sync.sync();
  }

  Future<void> _delete() async {
    if (!await confirmDelete(context, 'repair') || !mounted) return;
    final services = Services.of(context);
    services.db.delete(Tables.faultRepairs, _v['id'] as String);
    Navigator.of(context).pop();
    services.sync.sync();
  }

  void _addTechnician(String name) {
    final names = [
      for (final n in _technicians.text.split(','))
        if (n.trim().isNotEmpty) n.trim(),
    ];
    if (names.contains(name)) {
      names.remove(name);
    } else {
      names.add(name);
    }
    setState(() => _technicians.text = names.join(', '));
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final logbook = services.logbook;
    final technicians = {
      ...logbook.peopleWithRole('technician'),
      if (logbook.peopleWithRole('technician').isEmpty)
        ...logbook.names(Tables.people, activeOnly: true),
    };
    final chosen = {for (final n in _technicians.text.split(',')) n.trim()};
    return FormFrame(
      formKey: _form,
      title: widget.repair == null ? 'Record repair' : 'Edit repair',
      onSave: _save,
      onDelete: widget.repair != null && services.canChange(widget.repair!)
          ? _delete
          : null,
      children: [
        Text(
          widget.fault.fault['description'] as String? ?? '',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TimeStampField(label: 'Repair started', controller: _started),
        TimeStampField(
          label: 'Repair finished',
          controller: _finished,
          required: false,
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final name in technicians.values)
              FilterChip(
                label: Text(name),
                selected: chosen.contains(name),
                onSelected: (_) => _addTechnician(name),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _technicians,
          decoration: const InputDecoration(labelText: 'Technicians'),
          onChanged: (_) => setState(() {}),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _work,
          decoration: const InputDecoration(labelText: 'Work performed'),
          maxLines: 4,
          minLines: 2,
          validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _materials,
          decoration: const InputDecoration(
            labelText: 'Materials and parts used',
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _notes,
          decoration: const InputDecoration(labelText: 'Notes'),
          maxLines: 2,
        ),
        const SizedBox(height: 12),
        PhotoPicker(
          saved: widget.repair == null
              ? const []
              : widget.fault.photosOf(widget.repair!['id'] as String),
          added: _added,
          removed: _removed,
          onChanged: () => setState(() {}),
        ),
      ],
    );
  }
}

class SignoffForm extends StatefulWidget {
  const SignoffForm({super.key, required this.fault, this.signoff});
  final FaultCase fault;
  final DbRow? signoff;

  @override
  State<SignoffForm> createState() => _SignoffFormState();
}

class _SignoffFormState extends State<SignoffForm> {
  final _form = GlobalKey<FormState>();
  late final DbRow _v = {'result': 'pass', ...?widget.signoff};
  late final _at = TextEditingController(
    text: _v['tested_at'] as String? ?? faultNow(),
  );
  late final _notes = TextEditingController(text: _v['notes'] as String?);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _v['signatory_id'] ??= Services.of(context).sync.me;
  }

  @override
  void dispose() {
    _at.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final services = Services.of(context);
    services.db.save(Tables.faultSignoffs, {
      ..._v,
      'fault_id': widget.fault.id,
      'tested_at': _at.text.trim(),
      'notes': _notes.text.trim(),
    });
    Navigator.of(context).pop();
    services.sync.sync();
  }

  Future<void> _delete() async {
    if (!await confirmDelete(context, 'sign-off') || !mounted) return;
    final services = Services.of(context);
    services.db.delete(Tables.faultSignoffs, _v['id'] as String);
    Navigator.of(context).pop();
    services.sync.sync();
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final logbook = services.logbook;
    final signatories = {
      ...logbook.peopleWithRole('signatory'),
      ...logbook.peopleWithRole('admin'),
    };
    final noRepair = widget.fault.repairs.isEmpty;
    return FormFrame(
      formKey: _form,
      title: 'Test and sign off',
      onSave: _save,
      onDelete: widget.signoff != null && services.canChange(widget.signoff!)
          ? _delete
          : null,
      children: [
        if (noRepair && widget.signoff == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'No repair is recorded. Sign off only when the fault needs '
              'none (for example a class 1 fault that was checked).',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'pass',
              icon: Icon(Icons.verified),
              label: Text('Passed: close the fault'),
            ),
            ButtonSegment(
              value: 'fail',
              icon: Icon(Icons.replay),
              label: Text('Failed: repair again'),
            ),
          ],
          selected: {_v['result'] as String},
          onSelectionChanged: (s) => setState(() => _v['result'] = s.first),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _notes,
          decoration: const InputDecoration(
            labelText: 'Test done and final note',
          ),
          maxLines: 3,
        ),
        const SizedBox(height: 12),
        PersonField(
          label: 'Authorized signatory',
          people: signatories.isEmpty
              ? logbook.names(Tables.people, activeOnly: true)
              : signatories,
          value: _v['signatory_id'] as String?,
          onChanged: (id) => _v['signatory_id'] = id,
        ),
        TimeStampField(label: 'Tested and signed', controller: _at),
      ],
    );
  }
}
