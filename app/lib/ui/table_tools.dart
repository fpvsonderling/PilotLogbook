import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/table_filter.dart';
import '../data/table_pdf.dart';

/// Filters above a logbook list: dates, one chip per [fields] entry, a
/// search box, and the PDF export of what is shown. The same bar goes on
/// every logbook, so it only needs the rows, the fields and [labels]
/// (field key -> value -> name) to offer the choices.
class FilterBar<T> extends StatefulWidget {
  const FilterBar({
    super.key,
    required this.rows,
    required this.fields,
    required this.filter,
    required this.onChanged,
    this.labels = const {},
    this.onExport,
    this.search = true,
  });

  /// Every row, before filtering: the choices come from these.
  final List<T> rows;
  final List<FilterField<T>> fields;
  final Map<String, Map<String, String>> labels;
  final TableFilter filter;
  final ValueChanged<TableFilter> onChanged;
  final VoidCallback? onExport;

  /// Show the search box.
  final bool search;

  @override
  State<FilterBar<T>> createState() => _FilterBarState<T>();
}

class _FilterBarState<T> extends State<FilterBar<T>> {
  late final _search = TextEditingController(text: widget.filter.text);
  static final _day = DateFormat('yyyy-MM-dd');
  static final _short = DateFormat('dd.MM.yy');

  @override
  void didUpdateWidget(FilterBar<T> old) {
    super.didUpdateWidget(old);
    if (widget.filter.text != _search.text) _search.text = widget.filter.text;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _dates(String? from, String? to) =>
      widget.onChanged(widget.filter.withDates(from, to));

  Future<void> _pickDates() async {
    final f = widget.filter;
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: f.from != null && f.to != null
          ? DateTimeRange(
              start: DateTime.parse(f.from!),
              end: DateTime.parse(f.to!),
            )
          : null,
    );
    if (picked != null) {
      _dates(_day.format(picked.start), _day.format(picked.end));
    }
  }

  Widget _datesChip() {
    final f = widget.filter;
    final now = DateTime.now();
    final set = f.from != null || f.to != null;
    String show(String? d) =>
        d == null ? '…' : _short.format(DateTime.parse(d));
    final presets = [
      (
        'This month',
        DateTime(now.year, now.month),
        DateTime(now.year, now.month + 1, 0),
      ),
      (
        'Last month',
        DateTime(now.year, now.month - 1),
        DateTime(now.year, now.month, 0),
      ),
      ('Last 30 days', now.subtract(const Duration(days: 29)), now),
      ('This year', DateTime(now.year), DateTime(now.year, 12, 31)),
    ];
    return MenuAnchor(
      menuChildren: [
        for (final (label, from, to) in presets)
          MenuItemButton(
            onPressed: () => _dates(_day.format(from), _day.format(to)),
            child: Text(label),
          ),
        MenuItemButton(
          onPressed: _pickDates,
          child: const Text('Choose dates…'),
        ),
        if (set)
          MenuItemButton(
            onPressed: () => _dates(null, null),
            child: const Text('All dates'),
          ),
      ],
      builder: (context, menu, _) => FilterChip(
        key: const Key('filter-dates'),
        avatar: const Icon(Icons.date_range, size: 18),
        label: Text(set ? '${show(f.from)} – ${show(f.to)}' : 'Dates'),
        selected: set,
        showCheckmark: false,
        onSelected: (_) => menu.isOpen ? menu.close() : menu.open(),
        onDeleted: set ? () => _dates(null, null) : null,
      ),
    );
  }

  Widget _fieldChip(FilterField<T> field) {
    final options = filterOptions(
      widget.rows,
      field,
      widget.labels[field.key] ?? const {},
    );
    final chosen = widget.filter.chosen[field.key];
    void choose(String? v) =>
        widget.onChanged(widget.filter.withChoice(field.key, v));
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => choose(null),
          child: Text('All (${field.label})'),
        ),
        for (final o in options.entries)
          MenuItemButton(
            onPressed: () => choose(o.key),
            leadingIcon: o.key == chosen
                ? const Icon(Icons.check, size: 18)
                : null,
            child: Text(o.value),
          ),
      ],
      builder: (context, menu, _) => FilterChip(
        key: Key('filter-${field.key}'),
        label: Text(
          chosen == null
              ? field.label
              : '${field.label}: ${options[chosen] ?? widget.labels[field.key]?[chosen] ?? chosen}',
        ),
        selected: chosen != null,
        showCheckmark: false,
        onSelected: (_) => menu.isOpen ? menu.close() : menu.open(),
        onDeleted: chosen != null ? () => choose(null) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final search = SizedBox(
      width: narrow ? 150 : 220,
      height: 40,
      child: TextField(
        key: const Key('filter-search'),
        controller: _search,
        onChanged: (t) => widget.onChanged(widget.filter.withText(t)),
        decoration: const InputDecoration(
          isDense: true,
          prefixIcon: Icon(Icons.search, size: 20),
          hintText: 'Search',
          contentPadding: EdgeInsets.symmetric(vertical: 8),
        ),
      ),
    );
    final export = widget.onExport == null
        ? null
        : FilledButton.tonalIcon(
            key: const Key('export-pdf'),
            onPressed: widget.onExport,
            icon: const Icon(Icons.picture_as_pdf, size: 18),
            label: const Text('PDF'),
          );
    final items = <Widget>[
      if (widget.search) search,
      // On a phone the end of the bar is off screen, so PDF comes first.
      if (narrow) ?export,
      _datesChip(),
      for (final f in widget.fields) _fieldChip(f),
      if (!widget.filter.isEmpty)
        TextButton(
          key: const Key('filter-clear'),
          onPressed: () => widget.onChanged(const TableFilter()),
          child: const Text('Clear'),
        ),
      if (!narrow) ?export,
    ];
    // Phones scroll the bar sideways instead of stacking several rows of
    // chips above a short list.
    return narrow
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final w in items)
                  Padding(padding: const EdgeInsets.only(right: 8), child: w),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: items,
            ),
          );
  }
}

/// Builds the PDF of [rows] and hands it to the user: a "Save as" dialog on
/// Windows and macOS, the share sheet (Files, Drive, mail, ...) on phones.
Future<void> exportTablePdf<T>(
  BuildContext context, {
  required String title,
  required List<TableColumn<T>> columns,
  required List<T> rows,
  String filters = '',
  List<String> summary = const [],
}) async {
  try {
    final bytes = await tablePdf(
      title: title,
      columns: columns,
      rows: rows,
      filters: filters,
      summary: summary,
      regular: await rootBundle.load('assets/fonts/Barlow-Regular.ttf'),
      bold: await rootBundle.load('assets/fonts/Barlow-SemiBold.ttf'),
    );
    if (!context.mounted) return;
    await deliverPdf(
      context,
      title: title,
      bytes: bytes,
      what: '${rows.length} rows',
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('PDF export failed: $e')));
    }
  }
}

/// Hands a finished PDF to the user: a "Save as" dialog on Windows and
/// macOS, the share sheet (Files, Drive, mail, ...) on phones. [what] goes
/// in the "Saved ..." note.
Future<void> deliverPdf(
  BuildContext context, {
  required String title,
  required Uint8List bytes,
  String what = 'PDF',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  try {
    final name =
        '${title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}_'
        '${DateFormat('yyyy-MM-dd').format(DateTime.now())}.pdf';
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PDF', extensions: ['pdf']),
        ],
      );
      if (location == null) return;
      final path = location.path.toLowerCase().endsWith('.pdf')
          ? location.path
          : '${location.path}.pdf';
      await File(path).writeAsBytes(bytes);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved $what to $path'),
          action: SnackBarAction(label: 'Open', onPressed: () => _open(path)),
        ),
      );
    } else {
      final dir = await getTemporaryDirectory();
      final path = p.join(dir.path, name);
      await File(path).writeAsBytes(bytes);
      await _share(path, title, origin);
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('PDF export failed: $e')));
  }
}

Future<void> _share(String path, String title, Rect? origin) =>
    SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: 'application/pdf')],
        subject: title,
        sharePositionOrigin: origin,
      ),
    );

void _open(String path) {
  if (Platform.isWindows) {
    Process.run('cmd', ['/c', 'start', '', path]);
  } else if (Platform.isMacOS) {
    Process.run('open', [path]);
  } else {
    Process.run('xdg-open', [path]);
  }
}
