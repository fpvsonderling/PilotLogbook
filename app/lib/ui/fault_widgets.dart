import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../data/local_db.dart';
import '../data/logbook.dart';
import 'services.dart';
import 'theme.dart';

final faultTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

String faultNow() => faultTimeFormat.format(DateTime.now());

/// Severity classes as in the old AppSheet report.
const severityTitles = {
  1: 'Class 1: Monitor only',
  2: 'Class 2: Repair required',
  3: 'Class 3: Critical – UAS GROUNDED',
};

const severityHelp = {
  1: 'Can fly. Keep an eye on it at the next checks.',
  2: 'Can fly for now, but plan a repair.',
  3: 'Do not fly until it is repaired and tested.',
};

const statusTitles = {
  FaultStatus.open: 'Not fixed',
  FaultStatus.repaired: 'Repaired · waiting for test',
  FaultStatus.closed: 'Fixed and tested',
};

/// Foreground and background colour of a severity class.
(Color, Color) severityColors(BuildContext context, int severity) {
  final colors = CheckColors.of(context);
  final scheme = Theme.of(context).colorScheme;
  return switch (severity) {
    3 => (scheme.onError, scheme.error),
    2 => (colors.problem, colors.problemContainer),
    _ => (colors.skipped, colors.skippedContainer),
  };
}

(Color, Color) statusColors(BuildContext context, FaultStatus status) {
  final colors = CheckColors.of(context);
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    FaultStatus.closed => (colors.ok, colors.okContainer),
    FaultStatus.repaired => (
      scheme.onPrimaryContainer,
      scheme.primaryContainer,
    ),
    FaultStatus.open => (colors.problem, colors.problemContainer),
  };
}

class Pill extends StatelessWidget {
  const Pill(this.text, this.colors, {super.key, this.icon});
  final String text;
  final (Color, Color) colors;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: colors.$2,
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: colors.$1),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.$1, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

/// What the fault is on: the drone, the battery or the equipment text.
String faultSubject(
  FaultCase c,
  Map<String, String> aircraft,
  Map<String, String> batteries,
) {
  final f = c.fault;
  final parts = [
    if (aircraft[f['aircraft_id']] case final d?) 'Drone $d',
    if (batteries[f['battery_id']] case final b?) 'Battery $b',
    if ((f['equipment'] as String? ?? '').isNotEmpty) f['equipment'] as String,
  ];
  return parts.isEmpty ? 'Fault' : parts.join(' · ');
}

/// A people id, or a name kept as text by the import.
String personName(Map<String, String> people, Object? idOrName) {
  final v = idOrName as String? ?? '';
  return people[v] ?? v;
}

/// Shows a stored photo; downloads it once when it was taken elsewhere.
class FaultPhoto extends StatefulWidget {
  const FaultPhoto(this.row, {super.key, this.size = 72, this.fit});
  final DbRow row;
  final double size;
  final BoxFit? fit;

  @override
  State<FaultPhoto> createState() => _FaultPhotoState();
}

class _FaultPhotoState extends State<FaultPhoto> {
  Future<File?>? _file;
  String? _key;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(FaultPhoto old) {
    super.didUpdateWidget(old);
    _load();
  }

  void _load() {
    final key = '${widget.row['id']}:${widget.row['drive_file_id']}';
    if (key == _key) return;
    _key = key;
    _file = Services.of(context).sync.photoFile(widget.row);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: widget.size,
      child: FutureBuilder<File?>(
        future: _file,
        builder: (context, snap) {
          final f = snap.data;
          if (f != null) {
            return Image.file(f, fit: widget.fit ?? BoxFit.cover);
          }
          return ColoredBox(
            color: scheme.surfaceContainerHighest,
            child: Icon(
              snap.connectionState == ConnectionState.done
                  ? Icons.cloud_off
                  : Icons.image_outlined,
              color: scheme.onSurfaceVariant,
            ),
          );
        },
      ),
    );
  }
}

void showPhoto(BuildContext context, Widget image) => showDialog(
  context: context,
  builder: (context) => Dialog.fullscreen(
    backgroundColor: Colors.black,
    child: Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(child: Center(child: image)),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton.filledTonal(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ),
      ],
    ),
  ),
);

/// Saved photos of a step plus the ones picked in the form, with buttons
/// to take or pick more. Saved photos can be removed when [canRemove].
class PhotoPicker extends StatelessWidget {
  const PhotoPicker({
    super.key,
    required this.saved,
    required this.added,
    required this.removed,
    required this.onChanged,
    this.canRemove = true,
  });

  final List<DbRow> saved;
  final List<Uint8List> added;
  final Set<String> removed;
  final VoidCallback onChanged;
  final bool canRemove;

  static final _picker = ImagePicker();

  Future<void> _pick(ImageSource source) async {
    // Small enough to upload quickly over a field connection.
    final files = source == ImageSource.camera
        ? [
            ?await _picker.pickImage(
              source: source,
              maxWidth: 1600,
              maxHeight: 1600,
              imageQuality: 80,
            ),
          ]
        : await _picker.pickMultiImage(
            maxWidth: 1600,
            maxHeight: 1600,
            imageQuality: 80,
          );
    for (final f in files) {
      added.add(await f.readAsBytes());
    }
    if (files.isNotEmpty) onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final camera = _picker.supportsImageSource(ImageSource.camera);
    Widget tile(Widget image, VoidCallback? onRemove) => ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          InkWell(onTap: () => showPhoto(context, image), child: image),
          if (onRemove != null)
            Positioned(
              top: 2,
              right: 2,
              child: IconButton.filledTonal(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Remove photo',
                onPressed: onRemove,
                icon: const Icon(Icons.close),
              ),
            ),
        ],
      ),
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final r in saved)
          if (!removed.contains(r['id']))
            tile(
              FaultPhoto(r, size: 88),
              canRemove
                  ? () {
                      removed.add(r['id'] as String);
                      onChanged();
                    }
                  : null,
            ),
        for (final b in added)
          tile(Image.memory(b, width: 88, height: 88, fit: BoxFit.cover), () {
            added.remove(b);
            onChanged();
          }),
        if (camera)
          OutlinedButton.icon(
            onPressed: () => _pick(ImageSource.camera),
            icon: const Icon(Icons.photo_camera),
            label: const Text('Take photo'),
          ),
        OutlinedButton.icon(
          onPressed: () => _pick(ImageSource.gallery),
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(camera ? 'From gallery' : 'Add photos'),
        ),
      ],
    );
  }
}

/// A date and time as yyyy-MM-dd HH:mm:ss with a Now button.
class TimeStampField extends StatelessWidget {
  const TimeStampField({
    super.key,
    required this.label,
    required this.controller,
    this.required = true,
  });

  final String label;
  final TextEditingController controller;
  final bool required;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'yyyy-MM-dd HH:mm:ss',
        suffixIcon: TextButton(
          onPressed: () => controller.text = faultNow(),
          child: const Text('Now'),
        ),
      ),
      validator: (v) {
        final t = (v ?? '').trim();
        if (t.isEmpty) return required ? 'Required' : null;
        return DateTime.tryParse(t) == null ? 'yyyy-MM-dd HH:mm:ss' : null;
      },
    ),
  );
}

/// The frame of every fault form: a side dialog on a PC, the whole screen
/// on a phone, with Save, Cancel and (for saved entries) Delete.
Future<void> showFaultForm(BuildContext context, Widget form) => showDialog(
  context: context,
  builder: (context) => MediaQuery.sizeOf(context).width < 600
      ? Dialog.fullscreen(child: form)
      : Dialog(
          alignment: Alignment.centerRight,
          insetPadding: const EdgeInsets.all(16),
          child: SizedBox(width: 520, child: form),
        ),
);

class FormFrame extends StatelessWidget {
  const FormFrame({
    super.key,
    required this.formKey,
    required this.title,
    required this.onSave,
    required this.children,
    this.onDelete,
  });

  final GlobalKey<FormState> formKey;
  final String title;
  final VoidCallback onSave;
  final VoidCallback? onDelete;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Form(
      key: formKey,
      child: Column(
        children: [
          AppBar(
            automaticallyImplyLeading: false,
            leading: compact
                ? IconButton(
                    tooltip: 'Cancel',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  )
                : null,
            title: Text(title),
            actions: [
              if (onDelete != null)
                IconButton(
                  tooltip: 'Delete',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              if (!compact)
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              FilledButton(
                key: const Key('save-fault-form'),
                onPressed: onSave,
                child: const Text('Save'),
              ),
              const SizedBox(width: 12),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> confirmDelete(BuildContext context, String what) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text('Delete this $what?'),
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
    ) ==
    true;

/// A person picked from People; [fallback] is a name kept as text (old
/// imported entries) and shown as an extra choice.
class PersonField extends StatelessWidget {
  const PersonField({
    super.key,
    required this.label,
    required this.people,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Map<String, String> people;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final v = value ?? '';
    final options = {
      ...people,
      if (v.isNotEmpty && !people.containsKey(v)) v: v,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String?>(
        initialValue: v.isEmpty ? null : v,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final e in options.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: onChanged,
        validator: (v) => v == null ? 'Required' : null,
      ),
    );
  }
}
