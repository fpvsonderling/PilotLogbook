import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/maintenance.dart';
import '../data/maintenance_guide.dart';
import '../data/schema.dart';
import 'services.dart';
import 'theme.dart';

/// Opens the maintenance form; [maintenance] edits a saved one.
Future<void> openMaintenance(
  BuildContext context, {
  Maintenance? maintenance,
  String? aircraftId,
  String? batteryId,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => MaintenanceScreen(
      maintenance: maintenance,
      aircraftId: aircraftId,
      batteryId: batteryId,
    ),
  ),
);

const _lastTechnicianKey = 'maintenance_last_technician_id';

/// One maintenance: pick the drone and technician, then mark each assembly
/// Checked or write what was done. A battery set has only the Power System:
/// batteries go from drone to drone, so they are kept per set.
class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({
    super.key,
    this.maintenance,
    this.aircraftId,
    this.batteryId,
  });

  final Maintenance? maintenance;

  /// Drone or battery set to start with, for a new maintenance.
  final String? aircraftId;
  final String? batteryId;

  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  static final _stamp = DateFormat('yyyy-MM-dd HH:mm:ss');

  String? _aircraftId;
  String? _batteryId;

  /// Maintenance of a battery set rather than a drone.
  late bool _battery;
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
    _batteryId = m == null ? widget.batteryId : m.batteryId;
    _battery = _batteryId != null;
    _aircraftId = _battery ? null : m?.aircraftId ?? widget.aircraftId;
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

  /// The assemblies on the form. A drone row from before battery sets that
  /// has a Power System keeps showing it, so it is not lost on save.
  List<MaintenanceSection> get _sections {
    if (_battery) return batterySections;
    final old = widget.maintenance;
    final keepPower =
        old != null &&
        !old.isBattery &&
        old.value(batterySections.first).isNotEmpty;
    return [
      for (final s in maintenanceSections)
        if (s.column != powerSystem || keepPower) s,
    ];
  }

  int get _done => _sections.where((s) => _value(s).isNotEmpty).length;

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
    final sections = _sections.map((s) => s.column).toSet();
    services.db.save(Tables.maintenance, {
      if (widget.maintenance != null) 'id': widget.maintenance!.id,
      'performed_at': _stamp.format(_performedAt),
      'aircraft_id': _battery ? null : _aircraftId,
      'battery_id': _battery ? _batteryId : null,
      'technician_id': _technicianId,
      for (final s in maintenanceSections)
        s.column: sections.contains(s.column) ? _value(s) : '',
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
    final batteries = logbook.names(Tables.batteries, activeOnly: true);
    final allBatteries = logbook.names(Tables.batteries);
    final droneName = _aircraftId == null ? null : allDrones[_aircraftId];
    final batteryName = _batteryId == null ? null : allBatteries[_batteryId];
    final unitId = _battery ? _batteryId : _aircraftId;
    final sections = _sections;
    final done = _done;
    final total = sections.length;
    final ready = unitId != null && _technicianId != null && done > 0;
    final title = _battery
        ? batteryName == null
              ? 'Maintenance · battery set'
              : 'Maintenance · battery set $batteryName'
        : droneName == null
        ? 'Maintenance'
        : 'Maintenance · drone $droneName';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          // Also up here: on a phone the keyboard hides the bottom button.
          IconButton(
            key: const Key('save-maintenance-top'),
            tooltip: 'Save',
            onPressed: ready ? _save : null,
            icon: const Icon(Icons.check),
          ),
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
              if (widget.maintenance == null) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<bool>(
                    key: const Key('maintenance-kind'),
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('Drone'),
                        icon: Icon(Icons.flight),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('Battery set'),
                        icon: Icon(Icons.battery_full),
                      ),
                    ],
                    selected: {_battery},
                    onSelectionChanged: (v) => setState(() {
                      _battery = v.first;
                      _checked.clear();
                      for (final c in _work.values) {
                        c.clear();
                      }
                    }),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (_battery) ...[
                const _Label('Battery set'),
                _Chips(
                  options: {
                    if (_batteryId != null &&
                        !batteries.containsKey(_batteryId))
                      _batteryId!: batteryName ?? '?',
                    ...batteries,
                  },
                  selected: _batteryId,
                  empty: 'Add batteries under Reference data',
                  onSelected: (id) => setState(() => _batteryId = id),
                ),
              ] else ...[
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
              ],
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
                      for (final s in sections) {
                        _checked.add(s.column);
                      }
                    }),
                    icon: const Icon(Icons.done_all),
                    label: const Text('All checked'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final s in sections) ...[
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
                              : unitId == null
                              ? _battery
                                    ? 'Pick the battery set'
                                    : 'Pick the drone'
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
                IconButton(
                  key: Key('guide-${section.column}'),
                  tooltip: 'How to do it',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => showMaintenanceGuide(context, section),
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

/// Shows what to do on [section] and how, with pictures.
Future<void> showMaintenanceGuide(
  BuildContext context,
  MaintenanceSection section,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.75,
    minChildSize: 0.4,
    maxChildSize: 0.95,
    builder: (context, scroll) => _GuideView(section: section, scroll: scroll),
  ),
);

class _GuideView extends StatelessWidget {
  const _GuideView({required this.section, required this.scroll});

  final MaintenanceSection section;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = CheckColors.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final guide = maintenanceGuides[section.column];
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Text(section.title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        if (guide == null || guide.tasks.isEmpty)
          Text('No instruction for this assembly yet.', style: muted)
        else ...[
          if (guide.warning.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      guide.warning,
                      style: TextStyle(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (guide.intro.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(guide.intro),
          ],
          for (final task in guide.tasks) ...[
            const SizedBox(height: 20),
            Text(task.title, style: theme.textTheme.titleMedium),
            Text(task.code, style: muted),
            if (task.when.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule, size: 18, color: colors.ok),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      task.when,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
            if (task.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(task.text),
            ],
            for (final check in task.checks)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.check_box_outline_blank,
                      size: 18,
                      color: colors.ok,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(check)),
                  ],
                ),
              ),
            if (task.after.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                task.after,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
            for (final image in task.images)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: GestureDetector(
                  onTap: () => _showImage(context, image),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: ColoredBox(
                      color: Colors.white,
                      child: Image.asset(image, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Text('Source: FB3 UAS Maintenance Manual 2.4.8', style: muted),
        ],
      ],
    );
  }

  void _showImage(BuildContext context, String asset) => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.asset(asset, fit: BoxFit.contain),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              color: Colors.white,
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    ),
  );
}
