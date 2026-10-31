import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import '../data/schema.dart';
import 'services.dart';

Future<void> showFlightForm(
  BuildContext context, {
  required String kind,
  DbRow? flight,
}) => showDialog(
  context: context,
  builder: (context) => MediaQuery.sizeOf(context).width < 600
      // Phones: the whole screen, so the keyboard leaves room for the field.
      ? Dialog.fullscreen(
          child: FlightForm(kind: kind, flight: flight, compact: true),
        )
      : Dialog(
          alignment: Alignment.centerRight,
          insetPadding: const EdgeInsets.all(16),
          child: SizedBox(
            width: 460,
            child: FlightForm(kind: kind, flight: flight),
          ),
        ),
);

class FlightForm extends StatefulWidget {
  const FlightForm({
    super.key,
    required this.kind,
    this.flight,
    this.compact = false,
  });

  final String kind;
  final DbRow? flight;

  /// Narrow screen: a close button instead of Cancel, to fit the title.
  final bool compact;

  @override
  State<FlightForm> createState() => _FlightFormState();
}

class _FlightFormState extends State<FlightForm> {
  final _form = GlobalKey<FormState>();
  late final DbRow _v = {...?widget.flight};
  late final _takeoff = TextEditingController(
    text: _v['takeoff_at'] as String?,
  );
  late final _landing = TextEditingController(
    text: _v['landing_at'] as String?,
  );
  late final _used = TextEditingController(text: _text('used'));
  late final _temp = TextEditingController(text: _text('temp_c'));
  late final List<String> _what = missionParts(_v['mission'] as String?);
  late final _notes = TextEditingController(text: _v['notes'] as String?);

  static final _dateFormat = DateFormat('yyyy-MM-dd');
  static final _timeFormat = DateFormat('HH:mm:ss');

  String? _text(String key) => _v[key]?.toString();

  @override
  void initState() {
    super.initState();
    _v['date'] ??= _dateFormat.format(DateTime.now());
    // Flights marked with the earlier tick boxes, before What said it.
    for (final t in MissionTag.values) {
      if (_v[t.column] == 1 && !_what.contains(t.label)) _what.add(t.label);
    }
  }

  @override
  void dispose() {
    for (final c in [_takeoff, _landing, _used, _temp, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final services = Services.of(context);
    services.db.save(Tables.flights, {
      ..._v,
      'kind': widget.kind,
      'takeoff_at': _takeoff.text.trim(),
      'landing_at': _landing.text.trim(),
      'duration_s': flightSeconds(_takeoff.text, _landing.text),
      'used': double.tryParse(_used.text.trim().replaceAll(',', '.')),
      'temp_c': int.tryParse(_temp.text.trim()),
      'mission': _what.join(', '),
      for (final t in MissionTag.values)
        t.column: _what.contains(t.label) ? 1 : null,
      'notes': _notes.text.trim(),
    });
    Navigator.of(context).pop();
    services.sync.sync();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: const Text('Delete this flight?'),
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
    services.db.delete(Tables.flights, _v['id'] as String);
    Navigator.of(context).pop();
    services.sync.sync();
  }

  @override
  Widget build(BuildContext context) {
    final logbook = Services.of(context).logbook;
    final missions = logbook
        .names(Tables.missionTypes, activeOnly: true)
        .values;
    return Form(
      key: _form,
      child: Column(
        children: [
          AppBar(
            automaticallyImplyLeading: false,
            leading: widget.compact
                ? IconButton(
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  )
                : null,
            title: Text(widget.flight == null ? 'New flight' : 'Edit flight'),
            actions: [
              if (widget.flight != null &&
                  Services.of(context).canChange(widget.flight!))
                IconButton(
                  tooltip: 'Delete',
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                ),
              if (!widget.compact)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              FilledButton(
                key: const Key('save-flight'),
                onPressed: _save,
                child: const Text('Save'),
              ),
              const SizedBox(width: 12),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _DateField(
                  value: _v['date'] as String,
                  onChanged: (d) => setState(() => _v['date'] = d),
                ),
                _ChoiceField(
                  label: 'Project',
                  options: logbook.names(Tables.projects, activeOnly: true),
                  value: _v['project_id'] as String?,
                  onChanged: (id) => setState(() => _v['project_id'] = id),
                ),
                _ChoiceField(
                  label: 'Drone',
                  options: logbook.names(Tables.aircraft, activeOnly: true),
                  value: _v['aircraft_id'] as String?,
                  onChanged: (id) => setState(() => _v['aircraft_id'] = id),
                ),
                _TimeField(
                  label: 'Take off',
                  controller: _takeoff,
                  now: () => _timeFormat.format(DateTime.now()),
                ),
                _TimeField(
                  label: 'Land',
                  controller: _landing,
                  now: () => _timeFormat.format(DateTime.now()),
                ),
                _ChoiceField(
                  label: 'Battery',
                  options: logbook.names(Tables.batteries, activeOnly: true),
                  value: _v['battery_id'] as String?,
                  onChanged: (id) => setState(() => _v['battery_id'] = id),
                ),
                Row(
                  children: [
                    Expanded(child: _number('Used', _used, decimal: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _number('Temp °C', _temp)),
                  ],
                ),
                const SizedBox(height: 12),
                // Several can be picked, e.g. Double and Aborted; saved
                // comma separated as in AppSheet: "Double, Aborted".
                _MultiChoiceField(
                  label: 'What',
                  options: [
                    // Old flights may name things no longer in the list.
                    for (final p in _what)
                      if (!missions.contains(p) &&
                          !MissionTag.values.any((t) => t.label == p))
                        p,
                    ...missions,
                    for (final t in MissionTag.values) t.label,
                  ],
                  value: _what,
                  onChanged: (v) => setState(() {
                    _what
                      ..clear()
                      ..addAll(v);
                  }),
                ),
                _person(
                  'RP',
                  'rp_id',
                  logbook.peopleWithRole('pilot'),
                  required: true,
                ),
                _person('PA', 'pa_id', logbook.peopleWithRole('pilot')),
                _person(
                  'Spotter',
                  'spotter_id',
                  logbook.peopleWithRole('spotter'),
                ),
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: 3,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _number(
    String label,
    TextEditingController c, {
    bool decimal = false,
  }) => TextFormField(
    controller: c,
    decoration: InputDecoration(labelText: label),
    keyboardType: TextInputType.numberWithOptions(
      decimal: decimal,
      signed: true,
    ),
    validator: (v) {
      final t = (v ?? '').trim().replaceAll(',', '.');
      if (t.isEmpty) return null;
      return (decimal ? double.tryParse(t) : int.tryParse(t)) == null
          ? 'Number'
          : null;
    },
  );

  Widget _person(
    String label,
    String key,
    Map<String, String> people, {
    bool required = false,
  }) {
    final value = _v[key] as String?;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String?>(
        initialValue: people.containsKey(value) ? value : null,
        decoration: InputDecoration(labelText: label),
        items: [
          if (!required) const DropdownMenuItem(value: null, child: Text('—')),
          for (final e in people.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (id) => _v[key] = id,
        validator: (v) => required && v == null ? 'Required' : null,
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: const Text('Date'),
    subtitle: Text(value),
    trailing: const Icon(Icons.calendar_today),
    onTap: () async {
      final picked = await showDatePicker(
        context: context,
        initialDate: DateTime.tryParse(value) ?? DateTime.now(),
        firstDate: DateTime(2020),
        lastDate: DateTime(2100),
      );
      if (picked != null) onChanged(DateFormat('yyyy-MM-dd').format(picked));
    },
  );
}

/// A row of buttons, like the project and drone pickers in AppSheet.
class _ChoiceField extends FormField<String> {
  _ChoiceField({
    required String label,
    required Map<String, String> options,
    required String? value,
    required ValueChanged<String> onChanged,
  }) : super(
         initialValue: value,
         validator: (v) => v == null ? 'Required' : null,
         builder: (state) => Padding(
           padding: const EdgeInsets.only(bottom: 12),
           child: InputDecorator(
             decoration: InputDecoration(
               labelText: label,
               border: InputBorder.none,
               errorText: state.errorText,
             ),
             child: options.isEmpty
                 ? const Text('Add them under Reference data')
                 : Wrap(
                     spacing: 8,
                     runSpacing: 8,
                     children: [
                       for (final e in options.entries)
                         ChoiceChip(
                           label: Text(e.value),
                           selected: state.value == e.key,
                           onSelected: (_) {
                             state.didChange(e.key);
                             onChanged(e.key);
                           },
                         ),
                     ],
                   ),
           ),
         ),
       );
}

/// Chips where several can be on at once; [value] keeps the order picked.
class _MultiChoiceField extends FormField<List<String>> {
  _MultiChoiceField({
    required String label,
    required List<String> options,
    required List<String> value,
    required ValueChanged<List<String>> onChanged,
  }) : super(
         initialValue: [...value],
         validator: (v) => (v ?? []).isEmpty ? 'Required' : null,
         builder: (state) => Padding(
           padding: const EdgeInsets.only(bottom: 12),
           child: InputDecorator(
             decoration: InputDecoration(
               labelText: label,
               helperText: 'Pick one or more, e.g. Double and Aborted',
               border: InputBorder.none,
               errorText: state.errorText,
             ),
             child: Wrap(
               spacing: 8,
               runSpacing: 8,
               children: [
                 for (final o in options.toSet())
                   FilterChip(
                     label: Text(o),
                     selected: state.value!.contains(o),
                     onSelected: (on) {
                       final v = [
                         for (final p in state.value!)
                           if (p != o) p,
                         if (on) o,
                       ];
                       state.didChange(v);
                       onChanged(v);
                     },
                   ),
               ],
             ),
           ),
         ),
       );
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.controller,
    required this.now,
  });

  final String label;
  final TextEditingController controller;
  final String Function() now;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'HH:mm:ss',
        suffixIcon: TextButton(
          onPressed: () => controller.text = now(),
          child: const Text('Now'),
        ),
      ),
      validator: (v) => parseTimeOfDay(v) == null ? 'Time as HH:mm:ss' : null,
    ),
  );
}
