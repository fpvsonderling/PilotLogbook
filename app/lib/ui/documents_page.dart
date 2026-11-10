import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../data/documents.dart';
import '../data/local_db.dart';
import '../data/schema.dart';
import 'fault_widgets.dart' show confirmDelete;
import 'services.dart';
import 'theme.dart';

/// The documents every pilot needs (manuals, procedures, certificates).
/// Everyone sees and opens them; only the admin adds, changes and deletes.
/// Files live in Google Drive and each device keeps a copy, so they open
/// offline and are downloaded once, then only when they change in Drive.
class DocumentsPage extends StatelessWidget {
  const DocumentsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    // Rebuilt on sync too: the admin role is known after a sync.
    return DbBuilder(
      builder: (context) => Scaffold(
        floatingActionButton: services.isAdmin
            ? FloatingActionButton.extended(
                key: const Key('add-document'),
                onPressed: () => showDocumentForm(context),
                icon: const Icon(Icons.note_add),
                label: const Text('Add document'),
              )
            : null,
        body: Builder(
          builder: (context) {
            final sync = services.sync;
            final store = sync.documents;
            final rows = services.db.rows(
              Tables.documents,
              orderBy: 'title COLLATE NOCASE',
            );
            final withFile = [
              for (final r in rows)
                if (DocumentStore.hasFile(r)) r,
            ];
            final offline = store == null
                ? 0
                : withFile.where((r) => store.cached(r) != null).length;
            final theme = Theme.of(context);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Text(
                  'Documents · ${rows.length}',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (store != null && withFile.isNotEmpty)
                  Card(
                    child: SwitchListTile(
                      key: const Key('keep-offline'),
                      value: sync.keepDocumentsOffline,
                      onChanged: (v) => sync.keepDocumentsOffline = v,
                      title: const Text('Keep all documents on this device'),
                      subtitle: Text(
                        [
                          '$offline of ${withFile.length} available offline',
                          if (formatBytes(store.bytesUsed()).isNotEmpty)
                            formatBytes(store.bytesUsed()),
                        ].join(' · '),
                      ),
                    ),
                  ),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      services.isAdmin
                          ? 'No documents yet. Add them with "Add document".'
                          : 'No documents yet. The admin adds them.',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final r in rows) _DocumentTile(row: r),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({required this.row});
  final DbRow row;

  IconData get _icon {
    final mime = row['mime_type'] as String? ?? '';
    if (mime == 'application/pdf') return Icons.picture_as_pdf;
    if (mime.startsWith('image/')) return Icons.image;
    if (mime.contains('sheet') || mime.contains('excel')) {
      return Icons.table_chart;
    }
    if (mime.startsWith('video/')) return Icons.movie;
    if (!DocumentStore.hasFile(row)) return Icons.link;
    return Icons.description;
  }

  @override
  Widget build(BuildContext context) {
    final services = Services.of(context);
    final sync = services.sync;
    final id = row['id'] as String;
    final progress = sync.downloads[id];
    final hasFile = DocumentStore.hasFile(row);
    final cached = sync.documents?.cached(row) != null;
    final oldCopy = !cached && (sync.documents?.hasAnyCopy(row) ?? false);
    final notes = (row['notes'] as String? ?? '').trim();
    final error = sync.downloadErrors[id];
    final details = [
      if ((row['file_name'] as String? ?? '').isNotEmpty) row['file_name'],
      if (formatBytes(row['size_bytes'] as num?).isNotEmpty)
        formatBytes(row['size_bytes'] as num?),
    ].join(' · ');

    final Widget status;
    if (progress != null) {
      status = SizedBox.square(
        dimension: 28,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          strokeWidth: 3,
        ),
      );
    } else if (!hasFile) {
      status = const SizedBox.shrink();
    } else if (cached) {
      status = const Tooltip(
        message: 'On this device, opens offline',
        child: Icon(Icons.offline_pin, color: AppPalette.green),
      );
    } else {
      status = IconButton(
        tooltip: oldCopy ? 'New version: download' : 'Download for offline',
        icon: Icon(
          Icons.download_for_offline_outlined,
          color: oldCopy ? AppPalette.rust : null,
        ),
        onPressed: () => sync.documentFile(row),
      );
    }

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        leading: Icon(_icon, size: 32, color: AppPalette.green),
        title: Text(
          row['title'] as String? ?? '',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (notes.isNotEmpty) Text(notes),
            if (details.isNotEmpty)
              Text(details, style: Theme.of(context).textTheme.bodySmall),
            if (error != null)
              Text(
                'Download failed: $error',
                style: const TextStyle(color: AppPalette.rust),
              ),
          ],
        ),
        onTap: () => _open(context),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            status,
            if (services.isAdmin)
              PopupMenuButton<String>(
                key: Key('document-menu-$id'),
                onSelected: (v) async {
                  if (v == 'edit') {
                    showDocumentForm(context, row: row);
                  } else if (v == 'delete' &&
                      await confirmDelete(context, 'document')) {
                    services.db.delete(Tables.documents, id);
                    services.sync.sync();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final sync = Services.of(context).sync;
    final messenger = ScaffoldMessenger.of(context);
    final hasFile = DocumentStore.hasFile(row);
    final link = (row['url'] as String? ?? '').trim();
    if (!hasFile) {
      if (link.isEmpty) return;
      await Clipboard.setData(ClipboardData(text: link));
      messenger.showSnackBar(
        const SnackBar(content: Text('Link copied to the clipboard')),
      );
      return;
    }
    final file = await sync.documentFile(row);
    if (file == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Not on this device yet. Connect to the internet and try again.',
          ),
        ),
      );
      return;
    }
    final problem = await openDocumentFile(file);
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
    }
  }
}

/// Opens the file in the system's program for it; returns why it could not.
Future<String?> openDocumentFile(File file) async {
  try {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', file.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [file.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [file.path]);
    } else {
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done) {
        return result.type == ResultType.noAppToOpen
            ? 'No app on this device opens this kind of file'
            : 'Could not open the file: ${result.message}';
      }
    }
    return null;
  } catch (e) {
    return 'Could not open the file: $e';
  }
}

/// The admin's form to add a document, or change one ([row]): a title,
/// notes and the file, picked on this device or linked from Google Drive.
Future<void> showDocumentForm(BuildContext context, {DbRow? row}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DocumentForm(row: row),
    );

enum _Source { device, drive }

class _DocumentForm extends StatefulWidget {
  const _DocumentForm({this.row});
  final DbRow? row;

  @override
  State<_DocumentForm> createState() => _DocumentFormState();
}

class _DocumentFormState extends State<_DocumentForm> {
  late final _title = TextEditingController(
    text: widget.row?['title'] as String? ?? '',
  );
  late final _notes = TextEditingController(
    text: widget.row?['notes'] as String? ?? '',
  );
  final _link = TextEditingController();
  var _source = _Source.device;
  File? _picked;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.row != null;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final f = await openFile();
    if (f == null) return;
    setState(() {
      _picked = File(f.path);
      _error = null;
      if (_title.text.trim().isEmpty) {
        final name = f.name;
        final dot = name.lastIndexOf('.');
        _title.text = dot > 0 ? name.substring(0, dot) : name;
      }
    });
  }

  Future<void> _save() async {
    final services = Services.of(context);
    final sync = services.sync;
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give the document a title');
      return;
    }
    final link = _link.text.trim();
    final driveId = link.isEmpty ? null : driveFileId(link);
    final newFile = _source == _Source.device
        ? _picked != null
        : link.isNotEmpty;
    if (!_editing && !newFile) {
      setState(
        () => _error = _source == _Source.device
            ? 'Choose a file'
            : 'Paste a Google Drive link',
      );
      return;
    }
    if (_source == _Source.drive && link.isNotEmpty && driveId == null) {
      setState(() => _error = 'This is not a Google Drive link');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final values = <String, Object?>{
        if (widget.row != null) 'id': widget.row!['id'],
        'title': title,
        'notes': _notes.text.trim(),
      };
      if (newFile) {
        final info = _source == _Source.device
            ? await sync.uploadDocument(_picked!)
            : await sync.documentInfo(driveId!);
        values.addAll(info);
      }
      final id = services.db.save(Tables.documents, values);
      // The admin's own file need not come back down from Drive.
      final store = sync.documents;
      if (store != null && _source == _Source.device && _picked != null) {
        try {
          store.keep(services.db.byId(Tables.documents, id)!, _picked!);
        } catch (_) {
          // Downloaded on the next sync instead.
        }
      }
      sync.sync();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Not saved: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.row?['file_name'] as String? ?? '';
    return AlertDialog(
      title: Text(_editing ? 'Edit document' : 'Add document'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('document-title'),
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
                minLines: 1,
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              if (_editing && current.isNotEmpty) ...[
                Text('File: $current'),
                const SizedBox(height: 4),
                Text(
                  'To replace it, choose a new file below.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              if (!Services.of(context).sync.usesFirebase)
                SegmentedButton<_Source>(
                  segments: const [
                    ButtonSegment(
                      value: _Source.device,
                      icon: Icon(Icons.upload_file),
                      label: Text('From this device'),
                    ),
                    ButtonSegment(
                      value: _Source.drive,
                      icon: Icon(Icons.add_to_drive),
                      label: Text('Google Drive link'),
                    ),
                  ],
                  selected: {_source},
                  onSelectionChanged: _busy
                      ? null
                      : (s) => setState(() {
                          _source = s.first;
                          _error = null;
                        }),
                ),
              const SizedBox(height: 12),
              if (_source == _Source.device)
                OutlinedButton.icon(
                  key: const Key('pick-document'),
                  onPressed: _busy ? null : _pick,
                  icon: const Icon(Icons.attach_file),
                  label: Text(
                    _picked == null
                        ? 'Choose file'
                        : _picked!.uri.pathSegments.last,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else ...[
                TextField(
                  key: const Key('document-link'),
                  controller: _link,
                  decoration: const InputDecoration(
                    labelText: 'Google Drive link',
                    hintText: 'https://drive.google.com/file/d/…',
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'The file must be one the logbook\'s Google account can open.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppPalette.rust)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-document'),
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
