import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pilot_logbook/data/sync/sync_service.dart';

const execUrl = 'https://script.google.com/macros/s/abc/exec';
const echoUrl =
    'https://script.googleusercontent.com/macros/echo?user_content_key=k';

void main() {
  test('follows the 302 Apps Script answers a POST with', () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      seen.add('${request.method} ${request.url}');
      if (request.method == 'POST') {
        expect(jsonDecode(request.body), {'action': 'sync'});
        return http.Response('', 302, headers: {'location': echoUrl});
      }
      return http.Response(jsonEncode({'ok': true, 'seq': {}}), 200);
    });
    final answer = await AppsScriptTransport(execUrl, client: client)({
      'action': 'sync',
    });
    expect(answer['ok'], true);
    expect(seen, ['POST $execUrl', 'GET $echoUrl']);
  });

  test('reports the script error message', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({'ok': false, 'error': 'Wrong access token'}),
        200,
      ),
    );
    expect(
      () => AppsScriptTransport(execUrl, client: client)({}),
      throwsA(
        isA<SyncException>().having(
          (e) => e.message,
          'message',
          'Wrong access token',
        ),
      ),
    );
  });

  test('an HTML page instead of JSON gives a readable error', () async {
    final client = MockClient(
      (_) async => http.Response('<html>Sign in</html>', 200),
    );
    expect(
      () => AppsScriptTransport(execUrl, client: client)({}),
      throwsA(isA<SyncException>()),
    );
  });
}
