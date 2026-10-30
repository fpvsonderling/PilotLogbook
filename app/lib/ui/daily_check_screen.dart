import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/checklists.dart';
import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import 'services.dart';
import 'theme.dart';

/// Opens the daily check form; [check] edits a saved one.
Future<void> openDailyCheck(BuildContext context, {DailyCheck? check}) =>
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => DailyCheckScreen(check: check)));

const _lastPilotKey = 'daily_check_last_pilot_id';

/// Quick phrases for a problem note, so the pilot rarely has to type.
const _quickPhrases = [
  'crack',
  'play',
  'loose screw',
  'seal broken',
  'connector loose',
  'replace soon',
];

/// One daily check: pick the drone and pilot, then mark every section of
/// the drone's checklist OK, Problem or N/A.
class DailyCheckScreen extends StatefulWidget {
  const DailyCheckScreen({super.key, this.check});

  final DailyCheck? check;

  @override
  State<DailyCheckScreen> createState() => _DailyCheckScreenState();
}

class _DailyCheckScreenState extends State<DailyCheckScreen> {
  String? _aircraftId;
  String? _pilotId;
  late String _checkedAt;
  final _results = <String, SectionResult>{};

  /// Per-item marks (item index -> ok / problem) by section column.
  final _items = <String, Map<int, SectionResult>>{};

  /// Sections set to Problem with the button, not by flagging an item; they
  /// stay a problem even when every item is ticked OK.
  final _manualProblem = <String>{};
  final _notes = <String, TextEditingController>{};
  late final _generalNotes = TextEditingController(
    text: widget.check?.row['notes'] as String?,
  );
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    final row = widget.check?.row;
    _checkedAt =
        row?['checked_at'] as String? ??
        DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    _aircraftId = row?['aircraft_id'] as String?;
    _pilotId = row?['pilot_id'] as String?;
    for (final s in widget.check?.checklist.sections ?? <ChecklistSection>[]) {
      final r = sectionResult(row![s.column]);
      if (r == null) continue;
      _results[s.column] = r;
      if (r == SectionResult.ok) _setAllItems(s, SectionResult.ok);
      if (r == SectionResult.problem) {
        final note = row[s.column].toString();
        _note(s.column).text = note;
        final items = _itemsOf(s);
        for (var i = 0; i < s.items.length; i++) {
          if (note.contains(s.items[i])) items[i] = SectionResult.problem;
        }
        if (items.isEmpty) _manualProblem.add(s.column);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _pilotId ??= Services.of(context).db.setting(_lastPilotKey);
  }

  @override
  void dispose() {
    for (final c in _notes.values) {
      c.dispose();
    }
    _generalNotes.dispose();
    super.dispose();
  }

  TextEditingController _note(String column) =>
      _notes.putIfAbsent(column, TextEditingController.new);

  Checklist? _checklist(LocalDb db) {
    if (widget.check != null) return widget.check!.checklist;
    if (_aircraftId == null) return null;
    final a = db.byId(Tables.aircraft, _aircraftId!);
    return checklistForDrone(
      name: a?['name'] as String?,
      model: a?['model'] as String?,
    );
  }

  void _pickDrone(String id, LocalDb db) {
    final before = _checklist(db);
    setState(() {
      _aircraftId = id;
      // Another drone type has other sections.
      if (_checklist(db) != before) {
        _results.clear();
        _items.clear();
        _manualProblem.clear();
      }
    });
  }

  Map<int, SectionResult> _itemsOf(ChecklistSection s) =>
      _items.putIfAbsent(s.column, () => {});

  void _setAllItems(ChecklistSection s, SectionResult? r) {
    final items = _itemsOf(s)..clear();
    if (r != null) {
      for (var i = 0; i < s.items.length; i++) {
        items[i] = r;
      }
    }
  }

  void _mark(ChecklistSection s, SectionResult r) => setState(() {
    final off = _results[s.column] == r;
    _manualProblem.remove(s.column);
    if (off) {
      _results.remove(s.column);
      if (r == SectionResult.ok) _setAllItems(s, null);
      return;
    }
    _results[s.column] = r;
    switch (r) {
      case SectionResult.ok:
        _setAllItems(s, SectionResult.ok);
      case SectionResult.notUsed:
        _setAllItems(s, null);
      case SectionResult.problem:
        _manualProblem.add(s.column);
    }
  });

  /// Tapping an item cycles it: OK, then problem, then unmarked. The
  /// section follows: any problem makes it a problem, all OK makes it OK.
  void _tapItem(ChecklistSection s, int index) => setState(() {
    final items = _itemsOf(s);
    final item = s.items[index];
    final note = _note(s.column);
    switch (items[index]) {
      case null:
        items[index] = SectionResult.ok;
      case SectionResult.ok:
        items[index] = SectionResult.problem;
        if (!note.text.contains(item)) {
          note.text = note.text.trim().isEmpty
              ? '$item: '
              : '${note.text.trimRight()}; $item: ';
        }
      case _:
        items.remove(index);
        // Drop the item's own part of the note.
        note.text = note.text
            .split(';')
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty && !p.startsWith('$item:'))
            .join('; ');
    }
    if (items.containsValue(SectionResult.problem) ||
        _manualProblem.contains(s.column)) {
      _results[s.column] = SectionResult.problem;
    } else if (items.length == s.items.length) {
      _results[s.column] = SectionResult.ok;
    } else {
      _results.remove(s.column);
    }
  });

  void _addPhrase(ChecklistSection s, String phrase) => setState(() {
    final note = _note(s.column);
    final t = note.text.trimRight();
    note.text = t.isEmpty || t.endsWith(':')
        ? '$t $phrase'.trim()
        : '$t, $phrase';
  });

  String _value(ChecklistSection s) => switch (_results[s.column]!) {
    SectionResult.ok => okValue,
    SectionResult.notUsed => notUsedValue,
    SectionResult.problem =>
      _note(s.column).text.trim().isEmpty
          ? 'Problem'
          : _note(s.column).text.trim(),
  };

  Future<void> _save(Checklist checklist) async {
    final problems = [
      for (final s in checklist.sections)
        if (_results[s.column] == SectionResult.problem) (s, _value(s)),
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _SummaryDialog(problems: problems),
    );
    if (ok != true || !mounted) return;
    final services = Services.of(context);
    services.db.save(checklist.table, {
      if (widget.check != null) 'id': widget.check!.id,
      'checked_at': _checkedAt,
      'aircraft_id': _aircraftId,
      'pilot_id': _pilotId,
      for (final s in checklist.sections) s.column: _value(s),
      'notes': _generalNotes.text.trim(),
    });
    services.db.setSetting(_lastPilotKey, _pilotId);
    services.sync.sync();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          problems.isEmpty
              ? 'Daily check saved · ready to fly'
              : 'Daily check saved · ${problems.length} '
                    '${problems.length == 1 ? 'problem' : 'problems'}',
        ),
      ),
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('Delete this daily check?'),
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
    services.db.delete(widget.check!.checklist.table, widget.check!.id);
    services.sync.sync();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final db = services.db;
    final logbook = services.logbook;
    final checklist = _checklist(db);
    final drones = logbook.names(Tables.aircraft, activeOnly: true);
    final droneName = _aircraftId == null
        ? null
        : (db.byId(Tables.aircraft, _aircraftId!)?['name'] as String?);
    var pilots = logbook.peopleWithRole('pilot');
    if (pilots.isEmpty) pilots = logbook.names(Tables.people, activeOnly: true);
    final sections = checklist?.sections ?? const <ChecklistSection>[];
    final done = sections.where((s) => _results.containsKey(s.column)).length;
    final complete =
        checklist != null && done == sections.length && _pilotId != null;
    final problems = _aircraftId == null
        ? const <(DailyCheck, ChecklistSection, String)>[]
        : logbook.recentProblems(_aircraftId!, exceptId: widget.check?.id);
    final theme = Theme.of(context);

    String? lastGroup;
    final sectionWidgets = <Widget>[];
    for (final s in sections) {
      if (s.group != null && s.group != lastGroup) {
        sectionWidgets.add(_GroupHeader(s.group!));
        lastGroup = s.group;
      }
      sectionWidgets.add(
        _SectionCard(
          key: ValueKey(s.column),
          section: s,
          result: _results[s.column],
          note: _note(s.column),
          items: _itemsOf(s),
          onMark: (r) => _mark(s, r),
          onItem: (i) => _tapItem(s, i),
          onPhrase: (p) => _addPhrase(s, p),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          droneName == null
              ? 'Daily check'
              : 'Drone $droneName · ${checklist!.name}',
        ),
        actions: [
          if (widget.check != null && Services.of(context).isAdmin)
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
            value: sections.isEmpty ? 0 : done / sections.length,
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
              _Label('Pilot · $_checkedAt'),
              _Chips(
                options: pilots,
                selected: _pilotId,
                empty: 'Add pilots under Reference data',
                onSelected: (id) => setState(() => _pilotId = id),
              ),
              const SizedBox(height: 14),
              const _Label('Drone'),
              if (widget.check != null)
                Text(droneName ?? '', style: theme.textTheme.titleMedium)
              else
                _Chips(
                  options: drones,
                  selected: _aircraftId,
                  mono: true,
                  empty: 'Add drones under Reference data',
                  onSelected: (id) => _pickDrone(id, db),
                ),
              const SizedBox(height: 14),
              if (problems.isNotEmpty) ...[
                _PreviousProblems(problems: problems, drone: droneName ?? ''),
                const SizedBox(height: 14),
              ],
              if (checklist == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Pick the drone to see its checklist.',
                    style: theme.textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                )
              else ...[
                ...sectionWidgets.expand(
                  (w) => [w, const SizedBox(height: 12)],
                ),
                TextField(
                  controller: _generalNotes,
                  decoration: const InputDecoration(labelText: 'Other notes'),
                  maxLines: 2,
                ),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
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
                  key: const Key('save-check'),
                  onPressed: complete ? () => _save(checklist) : null,
                  child: Text(
                    complete
                        ? 'Review & save'
                        : checklist == null
                        ? 'Pick the drone'
                        : _pilotId == null
                        ? 'Pick the pilot'
                        : '$done / ${sections.length} sections',
                    style: const TextStyle(
                      fontFamily: 'Barlow Condensed',
                      fontSize: 22,
                    ),
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

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 6, 0, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
}

/// Big buttons in a wrapping row, for gloves and small screens.
class _Chips extends StatelessWidget {
  const _Chips({
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.empty,
    this.mono = false,
  });

  final Map<String, String> options;
  final String? selected;
  final ValueChanged<String> onSelected;
  final String empty;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return Text(empty);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final e in options.entries)
          ChoiceChip(
            label: ConstrainedBox(
              constraints: BoxConstraints(minWidth: mono ? 36 : 0),
              child: Text(
                e.value,
                textAlign: TextAlign.center,
                style: mono
                    ? const TextStyle(
                        fontFamily: 'Barlow',
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      )
                    : null,
              ),
            ),
            showCheckmark: false,
            selected: selected == e.key,
            onSelected: (_) => onSelected(e.key),
          ),
      ],
    );
  }
}

class _PreviousProblems extends StatelessWidget {
  const _PreviousProblems({required this.problems, required this.drone});

  final List<(DailyCheck, ChecklistSection, String)> problems;
  final String drone;

  @override
  Widget build(BuildContext context) {
    final colors = CheckColors.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.problemContainer,
        border: Border.all(color: colors.problem),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Previous problems · drone $drone',
            style: TextStyle(
              color: colors.problem,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          for (final (check, section, note) in problems)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${_shortDate(check.checkedAt)} · ${section.title}: $note',
              ),
            ),
        ],
      ),
    );
  }
}

/// "2026-10-27 11:26:53" -> "27.10"
String _shortDate(String checkedAt) {
  final d = DateTime.tryParse(checkedAt);
  return d == null ? checkedAt : DateFormat('dd.MM').format(d);
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    super.key,
    required this.section,
    required this.result,
    required this.note,
    required this.onMark,
    required this.items,
    required this.onItem,
    required this.onPhrase,
  });

  final ChecklistSection section;
  final SectionResult? result;
  final TextEditingController note;
  final ValueChanged<SectionResult> onMark;
  final Map<int, SectionResult> items;
  final ValueChanged<int> onItem;
  final ValueChanged<String> onPhrase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = CheckColors.of(context);
    final border = switch (result) {
      SectionResult.ok => colors.ok,
      SectionResult.problem => colors.problem,
      _ => theme.colorScheme.outlineVariant,
    };
    return Opacity(
      opacity: result == SectionResult.notUsed ? 0.75 : 1,
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border, width: result == null ? 1 : 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      section.title,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  _Badge(result: result, items: section.items.length),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _ResultButton(
                      label: 'OK',
                      icon: Icons.check,
                      color: colors.ok,
                      selected: result == SectionResult.ok,
                      onPressed: () => onMark(SectionResult.ok),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ResultButton(
                      label: 'Problem',
                      color: colors.problem,
                      selected: result == SectionResult.problem,
                      onPressed: () => onMark(SectionResult.problem),
                    ),
                  ),
                  if (section.canSkip) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ResultButton(
                        label: 'N/A',
                        color: colors.skipped,
                        selected: result == SectionResult.notUsed,
                        onPressed: () => onMark(SectionResult.notUsed),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (result == SectionResult.problem)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: note,
                      maxLines: null,
                      minLines: 2,
                      decoration: InputDecoration(
                        hintText: 'What is wrong?',
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: colors.problem,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final p in _quickPhrases)
                          ActionChip(
                            label: Text(p),
                            onPressed: () => onPhrase(p),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            if (result != SectionResult.notUsed)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Tap an item: OK → problem → clear',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      for (var i = 0; i < section.items.length; i++)
                        _Item(
                          text: section.items[i],
                          state: items[i],
                          onTap: () => onItem(i),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.result, required this.items});
  final SectionResult? result;
  final int items;

  @override
  Widget build(BuildContext context) {
    final colors = CheckColors.of(context);
    if (result == null) {
      return Text(
        '$items items',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
        ),
      );
    }
    final (label, fg, bg) = switch (result!) {
      SectionResult.ok => ('OK', colors.ok, colors.okContainer),
      SectionResult.problem => (
        'Problem',
        colors.problem,
        colors.problemContainer,
      ),
      SectionResult.notUsed => ('N/A', colors.skipped, colors.skippedContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13),
      ),
    );
  }
}

class _ResultButton extends StatelessWidget {
  const _ResultButton({
    required this.label,
    required this.color,
    required this.selected,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final Color color;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const text = TextStyle(
      fontFamily: 'Barlow',
      fontSize: 17,
      fontWeight: FontWeight.w700,
    );
    const size = Size(0, 52);
    final child = icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 6),
              Text(label),
            ],
          );
    return selected
        ? FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              minimumSize: size,
              textStyle: text,
            ),
            child: child,
          )
        : OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              foregroundColor: color,
              side: BorderSide(color: color, width: 2),
              minimumSize: size,
              textStyle: text,
            ),
            child: child,
          );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.text, required this.state, required this.onTap});

  final String text;
  final SectionResult? state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = CheckColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final fill = switch (state) {
      SectionResult.ok => colors.ok,
      SectionResult.problem => colors.problem,
      _ => null,
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: fill ?? scheme.outlineVariant,
                  width: 2,
                ),
              ),
              child: fill == null
                  ? null
                  : Icon(
                      state == SectionResult.ok
                          ? Icons.check
                          : Icons.priority_high,
                      size: 17,
                      color: Colors.white,
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(text, style: const TextStyle(fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryDialog extends StatelessWidget {
  const _SummaryDialog({required this.problems});
  final List<(ChecklistSection, String)> problems;

  @override
  Widget build(BuildContext context) {
    final colors = CheckColors.of(context);
    final good = problems.isEmpty;
    return AlertDialog(
      title: Text(
        good
            ? 'Ready to fly'
            : '${problems.length} ${problems.length == 1 ? 'problem' : 'problems'}',
        style: Theme.of(context).textTheme.headlineSmall
            ?.copyWith(color: good ? colors.ok : colors.problem),
      ),
      content: good
          ? const Text('All sections OK.')
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (s, note) in problems)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('${s.title}: $note'),
                  ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Back'),
        ),
        FilledButton(
          key: const Key('confirm-save-check'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
