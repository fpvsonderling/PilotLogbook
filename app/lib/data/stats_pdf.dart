import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'logbook.dart';

/// One big number at the top of the Statistic page.
class StatsFigure {
  const StatsFigure(this.label, this.value, {this.note, this.warn = false});
  final String label;
  final String value;
  final String? note;

  /// Shown in the warning colour (aborted missions, near misses).
  final bool warn;
}

/// One block of the Statistic page: flights per project, pilot, month...
class StatsSection {
  const StatsSection(
    this.title,
    this.rows, {
    this.total = false,
    this.time = true,
    this.safety = true,
    this.bars = false,
  });

  final String title;
  final List<FlightStat> rows;

  /// Add a Total row.
  final bool total;
  final bool time;

  /// Aborted and near miss counts.
  final bool safety;

  /// A bar column in the wide table on screen (phones and the PDF always
  /// have bars).
  final bool bars;

  int get most => rows.fold(0, (n, r) => r.flights > n ? r.flights : n);

  FlightStat get sum => FlightStat(
    '',
    'Total',
    flights: rows.fold(0, (n, r) => n + r.flights),
    seconds: rows.fold(0, (n, r) => n + r.seconds),
    aborted: rows.fold(0, (n, r) => n + r.aborted),
    nearMisses: rows.fold(0, (n, r) => n + r.nearMisses),
  );
}

/// The Statistic page as a portrait A4 PDF: the figures as a grid of boxes,
/// then every section as a table with bars. [regular] and [bold] are the
/// app's Barlow TTF fonts.
Future<Uint8List> statsPdf({
  required String title,
  required List<StatsFigure> figures,
  required List<StatsSection> sections,
  required ByteData regular,
  required ByteData bold,
  String filters = '',
  DateTime? printedAt,
}) {
  final font = pw.Font.ttf(regular);
  final boldFont = pw.Font.ttf(bold);
  final at = printedAt ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  const grey = PdfColor.fromInt(0xFF5F6B73);
  const line = PdfColor.fromInt(0xFFDDE3E6);
  const accent = PdfColor.fromInt(0xFF00838F);
  const warn = PdfColor.fromInt(0xFFC0560E);

  pw.Widget figure(StatsFigure f) => pw.Container(
    width: 125,
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: line),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(f.label, style: const pw.TextStyle(fontSize: 8, color: grey)),
        pw.SizedBox(height: 2),
        pw.Text(
          f.value,
          style: pw.TextStyle(
            font: boldFont,
            fontSize: 15,
            color: f.warn ? warn : null,
          ),
        ),
        if (f.note != null)
          pw.Text(f.note!, style: const pw.TextStyle(fontSize: 7, color: grey)),
      ],
    ),
  );

  pw.Widget section(StatsSection s) {
    final most = s.most;
    pw.Widget cell(String text, {bool right = false, bool strong = false}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(
            text,
            textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(fontSize: 8.5, font: strong ? boldFont : null),
          ),
        );
    pw.Widget bar(FlightStat r) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4.5),
      child: r.flights <= 0 || most == 0
          ? pw.SizedBox(height: 6)
          : pw.Row(
              children: [
                pw.Expanded(
                  flex: r.flights,
                  child: pw.Container(height: 6, color: accent),
                ),
                if (r.flights < most)
                  pw.Expanded(
                    flex: most - r.flights,
                    child: pw.SizedBox(height: 6),
                  ),
              ],
            ),
    );
    List<pw.Widget> row(FlightStat r, {bool strong = false}) => [
      cell(r.name, strong: strong),
      cell('${r.flights}', right: true, strong: strong),
      strong ? pw.SizedBox() : bar(r),
      if (s.time) cell(formatDuration(r.seconds), right: true, strong: strong),
      if (s.safety) ...[
        cell(r.aborted == 0 ? '' : '${r.aborted}', right: true, strong: strong),
        cell(
          r.nearMisses == 0 ? '' : '${r.nearMisses}',
          right: true,
          strong: strong,
        ),
      ],
    ];
    pw.Widget head(String t, {bool right = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        t,
        textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
        style: pw.TextStyle(font: boldFont, fontSize: 8, color: grey),
      ),
    );
    final widths = <pw.TableColumnWidth>[
      const pw.FlexColumnWidth(3),
      const pw.FixedColumnWidth(45),
      const pw.FlexColumnWidth(3),
      if (s.time) const pw.FixedColumnWidth(60),
      if (s.safety) ...const [pw.FixedColumnWidth(50), pw.FixedColumnWidth(55)],
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 14),
        pw.Text(s.title, style: pw.TextStyle(font: boldFont, fontSize: 12)),
        pw.SizedBox(height: 4),
        pw.Table(
          columnWidths: {for (var i = 0; i < widths.length; i++) i: widths[i]},
          border: const pw.TableBorder(
            horizontalInside: pw.BorderSide(color: line, width: 0.5),
          ),
          children: [
            pw.TableRow(
              children: [
                head('Name'),
                head('Flights', right: true),
                pw.SizedBox(),
                if (s.time) head('Time', right: true),
                if (s.safety) ...[
                  head('Aborted', right: true),
                  head('Near miss', right: true),
                ],
              ],
            ),
            for (final r in s.rows) pw.TableRow(children: row(r)),
            if (s.total && s.rows.length > 1)
              pw.TableRow(children: row(s.sum, strong: true)),
          ],
        ),
      ],
    );
  }

  final doc = pw.Document(title: title, creator: 'Pilot Logbook');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      theme: pw.ThemeData.withFont(base: font, bold: boldFont),
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            '$title · $stamp',
            style: const pw.TextStyle(fontSize: 7, color: grey),
          ),
          pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 7, color: grey),
          ),
        ],
      ),
      build: (context) => [
        pw.Text(title, style: pw.TextStyle(font: boldFont, fontSize: 18)),
        pw.SizedBox(height: 2),
        pw.Text(
          filters.isEmpty ? 'All flights' : 'Filter: $filters',
          style: const pw.TextStyle(fontSize: 9, color: grey),
        ),
        pw.SizedBox(height: 10),
        pw.Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final f in figures) figure(f)],
        ),
        for (final s in sections)
          if (s.rows.isNotEmpty) section(s),
      ],
    ),
  );
  return doc.save();
}
