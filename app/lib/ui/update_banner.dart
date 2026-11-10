import 'package:flutter/material.dart';

import '../data/update_check.dart';
import 'links.dart';
import 'services.dart';
import 'theme.dart';

/// How to install the new version on each system.
String updateSteps(String platform) => switch (platform) {
  'windows' =>
    'Sync first. Download the zip, close Pilot Logbook, unpack the zip over '
        'the old PilotLogbook folder and start pilot_logbook.exe again. '
        'Your data stays.',
  'android' =>
    'Sync first. Download the APK and install it over the old app '
        '(allow installing from this source if asked). Your data stays.',
  'ios' => 'Open the TestFlight app and tap Update next to Pilot Logbook.',
  'macos' =>
    'Sync first. Download the zip, unpack it and drag Pilot Logbook to '
        'Applications, replacing the old one. Your data stays.',
  _ => 'Download the new version from the release page.',
};

String _buttonLabel(String platform) =>
    platform == 'ios' ? 'Open TestFlight' : 'Download';

/// A strip at the top of the app while a newer version is published, plus
/// a one-time dialog when it is first noticed. Shows nothing otherwise.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key});

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  UpdateChecker? _updates;

  /// The release the dialog was shown for, so it pops up once per version.
  AppRelease? _told;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final updates = Services.of(context).updates;
    if (updates != _updates) {
      _updates?.removeListener(_changed);
      _updates = updates?..addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    _updates?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final newer = _updates?.newer;
    if (newer != null && newer != _told) {
      _told = newer;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showUpdateDialog(context, _updates!);
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final updates = _updates;
    final newer = updates?.newer;
    if (updates == null || newer == null) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? AppPalette.lightGarnet : AppPalette.garnet;
    return Material(
      key: const Key('update-banner'),
      color: dark ? AppPalette.darkGarnetContainer : AppPalette.garnetContainer,
      child: InkWell(
        onTap: () => showUpdateDialog(context, updates),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: [
              Icon(Icons.system_update, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'New version ${newer.version} is available. '
                  'Please install it.',
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: fg),
                onPressed: () => openLink(context, updates.downloadUrl!),
                child: Text(_buttonLabel(updates.platform)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Explains what to do and offers the download for this system.
Future<void> showUpdateDialog(BuildContext context, UpdateChecker updates) {
  final newer = updates.newer;
  if (newer == null) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('update-dialog'),
      icon: const Icon(Icons.system_update),
      title: const Text('Please install the new version'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pilot Logbook ${newer.version} is out. '
            'This copy is ${updates.current}.',
          ),
          const SizedBox(height: 12),
          Text(updateSteps(updates.platform)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Later'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.download),
          onPressed: () {
            Navigator.pop(dialogContext);
            openLink(context, updates.downloadUrl!);
          },
          label: Text(_buttonLabel(updates.platform)),
        ),
      ],
    ),
  );
}
