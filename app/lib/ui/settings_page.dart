import 'package:flutter/material.dart';

import '../data/sync/sync_service.dart';
import 'services.dart';

/// Where the spreadsheet's Apps Script lives and its access token.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController? _url;
  TextEditingController? _token;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final sync = Services.of(context).sync;
    _url ??= TextEditingController(text: sync.url);
    _token ??= TextEditingController(text: sync.token);
  }

  @override
  void dispose() {
    _url?.dispose();
    _token?.dispose();
    super.dispose();
  }

  Future<void> _saveAndSync() async {
    final services = Services.of(context);
    services.db.setSetting(SyncService.urlKey, _url!.text.trim());
    services.db.setSetting(SyncService.tokenKey, _token!.text.trim());
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
          'Paste the web app URL and the access token from the spreadsheet\'s '
          'Apps Script (see README).',
        ),
        TextField(
          controller: _url,
          decoration: const InputDecoration(
            labelText: 'Web app URL',
            hintText: 'https://script.google.com/macros/s/.../exec',
          ),
        ),
        TextField(
          controller: _token,
          decoration: const InputDecoration(labelText: 'Access token'),
          obscureText: true,
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
          builder: (context, _) => Text(
            sync.lastError != null
                ? 'Last error: ${sync.lastError}'
                : sync.lastSyncedAt != null
                ? 'Last sync: ${sync.lastSyncedAt}'
                : 'Not synced yet in this session',
          ),
        ),
      ],
    );
  }
}
