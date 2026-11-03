import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a web link (Google Maps, a Drive document) in the browser or its
/// app; when that is not possible the link is copied instead.
Future<void> openLink(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  var uri = Uri.tryParse(url.trim());
  if (uri != null && !uri.hasScheme) {
    uri = Uri.tryParse('https://${url.trim()}');
  }
  var opened = false;
  if (uri != null) {
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
  }
  if (!opened) {
    await Clipboard.setData(ClipboardData(text: url));
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not open it: link copied')),
    );
  }
}
