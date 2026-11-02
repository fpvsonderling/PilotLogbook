import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/schema.dart';
import 'services.dart';

/// The access key that connects this device to the company's data.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController? _link;
  bool _showKey = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _link ??= TextEditingController(text: Services.of(context).sync.accessKey);
  }

  @override
  void dispose() {
    _link?.dispose();
    super.dispose();
  }

  Future<void> _saveAndSync() async {
    final services = Services.of(context);
    if (!services.sync.setAccessKey(_link!.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This is not an access key. Copy the whole key you got from the '
            'administrator (it starts with PL1-).',
          ),
        ),
      );
      return;
    }
    // Shown as the key, also when an old-style link was pasted.
    _link!.text = services.sync.accessKey;
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
        Text('Access key', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text(
          'Paste the personal access key you got from the administrator. '
          'Keep it to yourself: it lets this device into the company logbook.',
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('connection-link'),
          controller: _link,
          keyboardType: TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          obscureText: !_showKey,
          decoration: InputDecoration(
            labelText: 'Access key',
            hintText: 'PL1-...',
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: _showKey ? 'Hide' : 'Show',
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
                // On a phone, long-pressing a long key to paste is fiddly.
                IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = data?.text?.trim();
                    if (text != null && text.isNotEmpty) _link!.text = text;
                  },
                ),
              ],
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
                sync.readOnly
                    ? 'Access: ${Services.of(context).logbook.names(Tables.people)[sync.me] ?? 'viewer'} '
                          '(read only: can see everything, change nothing)'
                    : sync.isAdmin
                    ? 'Access: administrator (can change and delete all data)'
                    : sync.me != null
                    ? 'Access: ${Services.of(context).logbook.names(Tables.people)[sync.me] ?? 'own key'} '
                          '(can change and delete own entries)'
                    : 'Access: add only (ask the admin for your own key '
                          'to change your entries)',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text(
          key: const Key('app-version'),
          'Pilot Logbook $appVersion',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Set by CI builds (--dart-define=APP_VERSION=1.3.0+42): version and build
/// number, so it is easy to see who still runs an old copy.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev build',
);
