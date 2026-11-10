import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/schema.dart';
import '../data/update_check.dart';
import 'services.dart';
import 'update_banner.dart';

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
        Text('Theme', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const _ThemeSwitch(),
        const SizedBox(height: 24),
        const _About(),
      ],
    );
  }
}

/// Light / dark / follow the device. Saved on this device only.
class _ThemeSwitch extends StatelessWidget {
  const _ThemeSwitch();

  @override
  Widget build(BuildContext context) {
    final theme = Services.of(context).theme;
    return ValueListenableBuilder(
      valueListenable: theme,
      builder: (context, mode, _) => SegmentedButton<ThemeMode>(
        key: const Key('theme-switch'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: ThemeMode.light,
            icon: Icon(Icons.light_mode),
            label: Text('Light'),
          ),
          ButtonSegment(
            value: ThemeMode.dark,
            icon: Icon(Icons.dark_mode),
            label: Text('Dark'),
          ),
          ButtonSegment(
            value: ThemeMode.system,
            icon: Icon(Icons.brightness_auto),
            label: Text('System'),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (s) => theme.value = s.first,
      ),
    );
  }
}

/// Who made the app, and its version.
class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Card(
      key: const Key('about'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('About', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('Author: Pavlo Yavorskyi'),
            const SizedBox(height: 4),
            const Text('Co-author: Claude (Anthropic)'),
            const SizedBox(height: 4),
            Text(
              'Written with the help of Claude, an AI assistant.',
              style: muted,
            ),
            const SizedBox(height: 12),
            Text(
              key: const Key('app-version'),
              'Pilot Logbook $appVersion',
              style: muted,
            ),
            const _UpdateStatus(),
          ],
        ),
      ),
    );
  }
}

/// Set by CI builds (--dart-define=APP_VERSION=1.3.0+42): version and build
/// number, so it is easy to see who still runs an old copy.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: 'dev build',
);

/// Under the version: whether a newer one is out, and a button to look.
class _UpdateStatus extends StatelessWidget {
  const _UpdateStatus();

  @override
  Widget build(BuildContext context) {
    final updates = Services.of(context).updates;
    if (updates == null || parseAppVersion(updates.current) == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: updates,
      builder: (context, _) {
        final newer = updates.newer;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: newer != null
              ? FilledButton.icon(
                  key: const Key('settings-update'),
                  icon: const Icon(Icons.system_update),
                  label: Text('Install version ${newer.version}'),
                  onPressed: () => showUpdateDialog(context, updates),
                )
              : OutlinedButton.icon(
                  key: const Key('settings-check-update'),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Check for a new version'),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final answered = await updates.check(force: true);
                    if (updates.newer == null) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            answered
                                ? 'This is the newest version'
                                : 'Could not check: no internet?',
                          ),
                        ),
                      );
                    }
                  },
                ),
        );
      },
    );
  }
}
