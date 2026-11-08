import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pilot_logbook/data/local_db.dart';
import 'package:pilot_logbook/data/update_check.dart';
import 'package:pilot_logbook/main.dart';

Map<String, dynamic> githubRelease({String tag = 'v1.8.0', int? build}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/fpvsonderling/PilotLogbook/releases/tag/$tag',
  'body':
      '**Windows:** ...\n\n'
      '${build == null ? '' : '<!-- pilotlogbook-build: $build (...) -->'}',
  'assets': [
    for (final name in [
      'PilotLogbook-windows-$tag.zip',
      'PilotLogbook-android-$tag.apk',
      'PilotLogbook-macos-$tag.zip',
    ])
      {'name': name, 'browser_download_url': 'https://dl/$name'},
  ],
};

AppRelease release({String tag = 'v1.8.0', int? build}) =>
    AppRelease.fromGitHub(githubRelease(tag: tag, build: build))!;

void main() {
  test('reads the GitHub release', () {
    final r = release(build: 210);
    expect(r.version, '1.8.0');
    expect(r.build, 210);
    expect(
      r.downloadUrl('windows'),
      'https://dl/PilotLogbook-windows-v1.8.0.zip',
    );
    expect(
      r.downloadUrl('android'),
      'https://dl/PilotLogbook-android-v1.8.0.apk',
    );
    expect(r.downloadUrl('macos'), 'https://dl/PilotLogbook-macos-v1.8.0.zip');
    expect(r.downloadUrl('ios'), UpdateChecker.testFlight);
    expect(r.downloadUrl('other'), r.pageUrl);
    expect(release().build, isNull);
  });

  test('build numbers decide when both have one', () {
    final latest = release(build: 210);
    expect(isOutdated('1.7.0+180', latest), isTrue);
    expect(isOutdated('1.8.0+210', latest), isFalse);
    // A TestFlight build from a later push keeps the old pubspec name.
    expect(isOutdated('1.3.0+215', latest), isFalse);
  });

  test('version names decide without a build number', () {
    final latest = release();
    expect(isOutdated('1.7.0+180', latest), isTrue);
    expect(isOutdated('1.8.0+1', latest), isFalse);
    expect(isOutdated('1.10.0+1', release(tag: 'v1.9.2')), isFalse);
    expect(isOutdated('1.8', latest), isFalse);
  });

  test('a copy run from source is never old', () {
    expect(isOutdated('dev build', release(build: 210)), isFalse);
  });

  test('checker reports a newer release and stays quiet offline', () async {
    var online = true;
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.toString(), UpdateChecker.latestApi);
      if (!online) throw http.ClientException('offline');
      return http.Response(jsonEncode(githubRelease(build: 210)), 200);
    });
    final checker = UpdateChecker(
      current: '1.7.0+180',
      client: client,
      platform: 'android',
    );
    online = false;
    expect(await checker.check(), isFalse);
    expect(checker.newer, isNull);
    online = true;
    // Offline did not count as a check: it asks again at once.
    expect(await checker.check(), isTrue);
    expect(checker.newer?.version, '1.8.0');
    expect(checker.downloadUrl, 'https://dl/PilotLogbook-android-v1.8.0.apk');
    expect(calls, 2);
    // Within the hour it does not ask again.
    await checker.check();
    expect(calls, 2);
    await checker.check(force: true);
    expect(calls, 3);
  });

  test('up to date: nothing to report', () async {
    final checker = UpdateChecker(
      current: '1.8.0+210',
      client: MockClient(
        (_) async => http.Response(jsonEncode(githubRelease(build: 210)), 200),
      ),
    );
    expect(await checker.check(), isTrue);
    expect(checker.newer, isNull);
  });

  testWidgets('old copy shows the dialog and the banner', (tester) async {
    final checker = UpdateChecker(
      current: '1.7.0+180',
      platform: 'windows',
      client: MockClient(
        (_) async => http.Response(jsonEncode(githubRelease(build: 210)), 200),
      ),
    );
    await tester.pumpWidget(
      PilotLogbookApp(db: LocalDb.inMemory(), updates: checker),
    );
    await tester.runAsync(() => checker.check(force: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-dialog')), findsOneWidget);
    expect(find.textContaining('Pilot Logbook 1.8.0 is out'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-dialog')), findsNothing);
    expect(find.byKey(const Key('update-banner')), findsOneWidget);
    expect(
      find.text('New version 1.8.0 is available. Please install it.'),
      findsOneWidget,
    );
    // Checking again does not pop the dialog up a second time.
    await tester.runAsync(() => checker.check(force: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-dialog')), findsNothing);
    // The banner opens it again.
    await tester.tap(find.byKey(const Key('update-banner')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-dialog')), findsOneWidget);
  });

  testWidgets('up-to-date copy shows no banner', (tester) async {
    await tester.pumpWidget(PilotLogbookApp(db: LocalDb.inMemory()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('update-banner')), findsNothing);
  });
}
