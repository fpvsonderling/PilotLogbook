import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/schema.dart';
import 'services.dart';

/// The connection link to the spreadsheet's Apps Script.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController? _link;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _link ??= TextEditingController(
      text: Services.of(context).sync.connectionLink,
    );
  }

  @override
  void dispose() {
    _link?.dispose();
    super.dispose();
  }

  Future<void> _saveAndSync() async {
    final services = Services.of(context);
    if (!services.sync.setConnectionLink(_link!.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This is not a connection link. Run connectionLink in Apps Script '
            'and copy the whole line that starts with https://',
          ),
        ),
      );
      return;
    }
    final result = await services.sync.sync();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == null
              ? 'Sync failed: ${services.sync.lastError ?? 'check the settings'}'
              : 'Synced: ${result.pushed} sent, ${result.pulled} received',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sync = Services.of(context).sync;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Google Sheets sync',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Paste the link that connectionLink printed in Apps Script '
          '(see README).',
        ),
        TextField(
          key: const Key('connection-link'),
          controller: _link,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Connection link',
            hintText: 'https://script.google.com/macros/s/.../exec?key=...',
            // On a phone, long-pressing a long link to paste is fiddly.
            suffixIcon: IconButton(
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste),
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final text = data?.text?.trim();
                if (text != null && text.isNotEmpty) _link!.text = text;
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _saveAndSync,
            icon: const Icon(Icons.sync),
            label: const Text('Save and sync'),
          ),
        ),
        const SizedBox(height: 16),
        ListenableBuilder(
          listenable: sync,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sync.lastError != null
                    ? 'Last error: ${sync.lastError}'
                    : sync.lastSyncedAt != null
                    ? 'Last sync: ${sync.lastSyncedAt}'
                    : 'Not synced yet in this session',
              ),
              const SizedBox(height: 8),
              Text(
                key: const Key('access-level'),
                sync.isAdmin
                    ? 'Access: administrator (can change and delete all data)'
                    : sync.me != null
                    ? 'Access: ${Services.of(context).logbook.names(Tables.people)[sync.me] ?? 'own link'} '
                          '(can change and delete own entries)'
                    : 'Access: add only (ask the admin for your own link '
                          'to change your entries)',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
