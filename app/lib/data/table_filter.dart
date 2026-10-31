/// Filters and columns shared by every logbook list (flights, daily checks,
/// fault reports, ...), so the screen and its PDF export show the same rows.
library;

/// One column of a logbook table, on screen and in the PDF.
class TableColumn<T> {
  const TableColumn(this.header, this.width, this.cell);
  final String header;

  /// Width on screen; the PDF shares out the page width in the same ratio.
  final double width;
  final String Function(T row) cell;
}

/// A "pick one" filter, such as the drone or the project.
class FilterField<T> {
  const FilterField(this.key, this.label, this.values);
  final String key;
  final String label;

  /// The values a row has for this field (ids or plain text). A row passes
  /// when any of them is the chosen one, so "Pilot" can match the RP, the
  /// PA or the spotter of a flight.
  final Iterable<String?> Function(T row) values;
}

/// What a list is filtered by: a date range, a chosen value per field and
/// free text.
class TableFilter {
  const TableFilter({
    this.from,
    this.to,
    this.text = '',
    this.chosen = const {},
  });

  /// yyyy-MM-dd, both ends included.
  final String? from;
  final String? to;
  final String text;

  /// Field key -> chosen value.
  final Map<String, String> chosen;

  bool get isEmpty =>
      from == null && to == null && text.trim().isEmpty && chosen.isEmpty;

  /// How many filters are set, for the badge on the phone's filter button.
  int get count =>
      (from != null || to != null ? 1 : 0) +
      (text.trim().isEmpty ? 0 : 1) +
      chosen.length;

  TableFilter withDates(String? from, String? to) =>
      TableFilter(from: from, to: to, text: text, chosen: chosen);

  TableFilter withText(String text) =>
      TableFilter(from: from, to: to, text: text, chosen: chosen);

  /// [value] null clears the field.
  TableFilter withChoice(String key, String? value) => TableFilter(
    from: from,
    to: to,
    text: text,
    chosen: {
      for (final e in chosen.entries)
        if (e.key != key) e.key: e.value,
      key: ?value,
    },
  );

  /// The rows that pass. [date] gives a row's day as yyyy-MM-dd (longer
  /// strings such as "yyyy-MM-dd HH:mm:ss" are cut); [columns] are searched
  /// for [text].
  List<T> apply<T>(
    List<T> rows, {
    required String Function(T row) date,
    List<FilterField<T>> fields = const [],
    List<TableColumn<T>> columns = const [],
  }) {
    final words = text
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final active = [
      for (final f in fields)
        if (chosen[f.key] != null) (f, chosen[f.key]!),
    ];
    return [
      for (final r in rows)
        if (_inRange(date(r)) &&
            active.every((a) => a.$1.values(r).contains(a.$2)) &&
            (words.isEmpty || _matches(r, columns, words)))
          r,
    ];
  }

  bool _inRange(String day) {
    final d = day.length > 10 ? day.substring(0, 10) : day;
    if (from != null && d.compareTo(from!) < 0) return false;
    if (to != null && d.compareTo(to!) > 0) return false;
    return true;
  }

  static bool _matches<T>(
    T row,
    List<TableColumn<T>> columns,
    List<String> words,
  ) {
    final all = [for (final c in columns) c.cell(row)].join(' ').toLowerCase();
    return words.every(all.contains);
  }

  /// One line for the PDF header, e.g. "2026-10-01 – 2026-10-31 · Drone: 18".
  /// [names] turns a field's chosen value into what the user picked.
  String describe<T>(
    List<FilterField<T>> fields,
    String Function(String key, String value) names,
  ) => [
    if (from != null || to != null) '${from ?? '…'} – ${to ?? '…'}',
    for (final f in fields)
      if (chosen[f.key] != null) '${f.label}: ${names(f.key, chosen[f.key]!)}',
    if (text.trim().isNotEmpty) '"${text.trim()}"',
  ].join(' · ');
}

/// The choices a field offers: only values some row has, so the list stays
/// short. [labels] names ids (drone id -> "18"); values without a label are
/// shown as they are. Sorted by label.
Map<String, String> filterOptions<T>(
  List<T> rows,
  FilterField<T> field, [
  Map<String, String> labels = const {},
]) {
  final seen = <String>{
    for (final r in rows)
      for (final v in field.values(r))
        if (v != null && v.trim().isNotEmpty) v,
  };
  final entries = [for (final v in seen) MapEntry(v, labels[v] ?? v)]
    ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
  return Map.fromEntries(entries);
}
