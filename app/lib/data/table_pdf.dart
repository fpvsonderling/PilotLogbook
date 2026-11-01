import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'table_filter.dart';

/// A logbook list as a landscape A4 PDF: title, the filters used, a few
/// totals and the table, repeated column headers and page numbers on every
/// page. [regular] and [bold] are TTF fonts (the app's Barlow), which also
/// have the Danish and Polish letters the built-in PDF fonts lack.
Future<Uint8List> tablePdf<T>({
  required String title,
  required List<TableColumn<T>> columns,
  required List<T> rows,
  required ByteData regular,
  required ByteData bold,
  String filters = '',
  List<String> summary = const [],
  DateTime? printedAt,
}) {
  final font = pw.Font.ttf(regular);
  final boldFont = pw.Font.ttf(bold);
  final at = printedAt ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
  const grey = PdfColor.fromInt(0xFF5F6B73);

  final doc = pw.Document(title: title, creator: 'Pilot Logbook');
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
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
        pw.Text(title, style: pw.TextStyle(font: boldFont, fontSize: 16)),
        pw.SizedBox(height: 2),
        pw.Text(
          filters.isEmpty ? 'All entries' : 'Filter: $filters',
          style: const pw.TextStyle(fontSize: 9, color: grey),
        ),
        if (summary.isNotEmpty) ...[
          pw.SizedBox(height: 2),
          pw.Text(
            summary.join('   ·   '),
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
        pw.SizedBox(height: 10),
        if (rows.isEmpty)
          pw.Text('Nothing matches the filter.')
        else
          pw.TableHelper.fromTextArray(
            headers: [for (final c in columns) c.header],
            data: [
              for (final r in rows) [for (final c in columns) c.cell(r)],
            ],
            columnWidths: {
              for (var i = 0; i < columns.length; i++)
                i: pw.FlexColumnWidth(columns[i].width),
            },
            headerStyle: pw.TextStyle(
              font: boldFont,
              fontSize: 7.5,
              color: PdfColors.white,
            ),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xFF263238),
            ),
            cellStyle: const pw.TextStyle(fontSize: 7.5),
            cellAlignment: pw.Alignment.centerLeft,
            headerAlignment: pw.Alignment.centerLeft,
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 3,
              vertical: 2.5,
            ),
            oddRowDecoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xFFF1F4F6),
            ),
            border: null,
          ),
      ],
    ),
  );
  return doc.save();
}
