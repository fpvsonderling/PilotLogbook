import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/maintenance.dart';
import '../data/schema.dart';
import 'services.dart';
import 'theme.dart';

/// Opens the maintenance form; [maintenance] edits a saved one.
Future<void> openMaintenance(
  BuildContext context, {
  Maintenance? maintenance,
  String? aircraftId,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) =>
        MaintenanceScreen(maintenance: maintenance, aircraftId: aircraftId),
  ),
);

const _lastTechnicianKey = 'maintenance_last_technician_id';

/// One maintenance: pick the drone and technician, then mark each assembly
/// Checked or write what was done.
class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({super.key, this.maintenance, this.aircraftId});

  final Maintenance? maintenance;

  /// Drone to start with, for a new maintenance.
  final String? aircraftId;

  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  static final _stamp = DateFormat('yyyy-MM-dd HH:mm:ss');

  String? _aircraftId;
  String? _technicianId;
  late DateTime _performedAt;
  final _checked = <String>{};
  final _work = <String, TextEditingController>{};
  late final _notes = TextEditingController(
    text: widget.maintenance?.row['notes'] as String?,
  );
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final m = widget.maintenance;
    _performedAt = DateTime.tryParse(m?.performedAt ?? '') ?? DateTime.now();
    _aircraftId = m?.aircraftId ?? widget.aircraftId;
    _technicianId = m?.row['technician_id'] as String?;
    if ((_technicianId ?? '').isEmpty) _technicianId = null;
    for (final s in maintenanceSections) {
      final v = m?.value(s) ?? '';
      if (v.isEmpty) continue;
      _checked.add(s.column);
      if (!isJustChecked(v)) _controller(s).text = v;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    if (widget.maintenance == null) {
      _technicianId ??= Services.of(context).db.setting(_lastTechnicianKey);
    }
  }

  @override
  void dispose() {
    for (final c in _work.values) {
      c.dispose();
    }
    _notes.dispose();
    super.dispose();
  }

  TextEditingController _controller(MaintenanceSection s) =>
      _work.putIfAbsent(s.column, TextEditingController.new);

  String _value(MaintenanceSection s) {
    final text = _controller(s).text.trim();
    if (text.isNotEmpty) return text;
    return _checked.contains(s.column) ? checkedValue : '';
  }

  int get _done =>
      maintenanceSections.where((s) => _value(s).isNotEmpty).length;

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _performedAt,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_performedAt),
    );
    if (!mounted) return;
    setState(() {
      _performedAt = DateTime(
        d.year,
        d.month,
        d.day,
        t?.hour ?? _performedAt.hour,
        t?.minute ?? _performedAt.minute,
      );
    });
  }

  void _save() {
    final services = Services.of(context);
    services.db.save(Tables.maintenance, {
      if (widget.maintenance != null) 'id': widget.maintenance!.id,
      'performed_at': _stamp.format(_performedAt),
      'aircraft_id': _aircraftId,
      'technician_id': _technicianId,
      for (final s in maintenanceSections) s.column: _value(s),
      'notes': _notes.text.trim(),
    });
    services.db.setSetting(_lastTechnicianKey, _technicianId);
    services.sync.sync();
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(const SnackBar(content: Text('Maintenance saved')));
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('Delete this maintenance?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final services = Services.of(context);
    services.db.delete(Tables.maintenance, widget.maintenance!.id);
    services.sync.sync();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final logbook = services.logbook;
    final theme = Theme.of(context);
    final drones = logbook.names(Tables.aircraft, activeOnly: true);
    var technicians = logbook.peopleWithRole('technician');
    if (technicians.isEmpty) {
      technicians = logbook.names(Tables.people, activeOnly: true);
    }
    // An edited row keeps showing a technician or drone no longer listed.
    final allPeople = logbook.names(Tables.people);
    final allDrones = logbook.names(Tables.aircraft);
    if (_technicianId != null && !technicians.containsKey(_technicianId)) {
      technicians = {
        _technicianId!: allPeople[_technicianId] ?? _technicianId!,
        ...technicians,
      };
    }
    final droneName = _aircraftId == null ? null : allDrones[_aircraftId];
    final done = _done;
    final total = maintenanceSections.length;
    final ready = _aircraftId != null && _technicianId != null && done > 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          droneName == null ? 'Maintenance' : 'Maintenance · drone $droneName',
        ),
        actions: [
          if (widget.maintenance != null &&
              services.canChange(widget.maintenance!.row))
            IconButton(
              tooltip: 'Delete',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(6),
          child: LinearProgressIndicator(
            minHeight: 6,
            value: done / total,
            color: CheckColors.of(context).ok,
            backgroundColor: theme.colorScheme.outlineVariant,
          ),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
            children: [
              const _Label('Date'),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('maintenance-date'),
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text(
                    DateFormat('dd.MM.yyyy HH:mm').format(_performedAt),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const _Label('Technician'),
              _Chips(
                options: technicians,
                selected: _technicianId,
                empty: 'Add people under Reference data',
                onSelected: (id) => setState(() => _technicianId = id),
              ),
              const SizedBox(height: 14),
              const _Label('Drone'),
              _Chips(
                options: {
                  if (_aircraftId != null && !drones.containsKey(_aircraftId))
                    _aircraftId!: droneName ?? '?',
                  ...drones,
                },
                selected: _aircraftId,
                empty: 'Add drones under Reference data',
                onSelected: (id) => setState(() => _aircraftId = id),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Assemblies · $done / $total',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('all-checked'),
                    onPressed: () => setState(() {
                      for (final s in maintenanceSections) {
                        _checked.add(s.column);
                      }
                    }),
                    icon: const Icon(Icons.done_all),
                    label: const Text('All checked'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final s in maintenanceSections) ...[
                _SectionCard(
                  key: ValueKey(s.column),
                  section: s,
                  checked: _checked.contains(s.column),
                  work: _controller(s),
                  onChecked: (on) => setState(() {
                    if (on) {
                      _checked.add(s.column);
                    } else {
                      _checked.remove(s.column);
                      _controller(s).clear();
                    }
                  }),
                  onWorkChanged: () => setState(() {
                    if (_controller(s).text.trim().isNotEmpty) {
                      _checked.add(s.column);
                    }
                  }),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Other notes'),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                padding: const EdgeInsets.all(12),
                child: Center(
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton(
                        key: const Key('save-maintenance'),
                        onPressed: ready ? _save : null,
                        child: Text(
                          ready
                              ? 'Save'
                              : _technicianId == null
                              ? 'Pick the technician'
                              : _aircraftId == null
                              ? 'Pick the drone'
                              : 'Mark at least one assembly',
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        letterSpacing: 1,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// Big buttons in a wrapping row, for gloves and small screens.
class _Chips extends StatelessWidget {
  const _Chips({
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.empty,
  });

  final Map<String, String> options;
  final String? selected;
  final ValueChanged<String> onSelected;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return Text(empty);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in options.entries)
          ChoiceChip(
            label: Text(e.value),
            showCheckmark: false,
            selected: selected == e.key,
            onSelected: (_) => onSelected(e.key),
          ),
      ],
    );
  }
}

/// One assembly: a Checked toggle and what was done, if anything.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.section,
    required this.checked,
    required this.work,
    required this.onChecked,
    required this.onWorkChanged,
  });

  final MaintenanceSection section;
  final bool checked;
  final TextEditingController work;
  final ValueChanged<bool> onChecked;
  final VoidCallback onWorkChanged;

  @override
  Widget build(BuildContext context) {
    final colors = CheckColors.of(context);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  checked ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: checked
                      ? colors.ok
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    section.title,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                FilterChip(
                  key: Key('checked-${section.column}'),
                  label: const Text(checkedValue),
                  selected: checked,
                  selectedColor: colors.okContainer,
                  onSelected: onChecked,
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: Key('work-${section.column}'),
              controller: work,
              onChanged: (_) => onWorkChanged(),
              decoration: const InputDecoration(
                hintText: 'Work done, parts replaced (optional)',
                isDense: true,
              ),
              maxLines: null,
            ),
          ],
        ),
      ),
    );
  }
}
