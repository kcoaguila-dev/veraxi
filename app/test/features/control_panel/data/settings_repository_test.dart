import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/features/control_panel/data/settings_repository.dart';

// SettingsRepository calls the top-level http.get() function directly rather
// than an injected client, so these tests use http.runWithClient to swap in
// a MockClient for the duration of each call via a Zone value, without
// touching the SettingsRepository implementation.
void main() {
  group('SettingsRepository.fetchStats', () {
    test('returns parsed BackendStats on a successful response', () async {
      final repository = SettingsRepository();

      final stats = await http.runWithClient(
        () => repository.fetchStats(),
        () => MockClient((request) async {
          expect(request.url.path, '/api/admin/stats');
          return http.Response(
              jsonEncode({'node_count': 4, 'vector_count': 9}), 200);
        }),
      );

      expect(stats.nodeCount, 4);
      expect(stats.vectorCount, 9);
    });

    test('throws an exception with the status code on non-200 responses',
        () async {
      final repository = SettingsRepository();

      await expectLater(
        http.runWithClient(
          () => repository.fetchStats(),
          () => MockClient((request) async => http.Response('oops', 503)),
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Server error: 503'),
          ),
        ),
      );
    });

    test('translates SocketException into a friendly network error',
        () async {
      final repository = SettingsRepository();

      await expectLater(
        http.runWithClient(
          () => repository.fetchStats(),
          () => MockClient((request) async {
            throw const SocketException('Failed host lookup');
          }),
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Network error: Unable to connect to the server.'),
          ),
        ),
      );
    });

    test('translates TimeoutException into a friendly timeout message',
        () async {
      final repository = SettingsRepository();

      await expectLater(
        http.runWithClient(
          () => repository.fetchStats(),
          () => MockClient((request) async {
            throw TimeoutException('too slow');
          }),
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Connection timeout: Server took too long to respond.'),
          ),
        ),
      );
    });

    test('wraps unexpected errors with their original message', () async {
      final repository = SettingsRepository();

      await expectLater(
        http.runWithClient(
          () => repository.fetchStats(),
          () => MockClient((request) async {
            throw const FormatException('bad data');
          }),
        ),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('bad data'),
          ),
        ),
      );
    });
  });
}