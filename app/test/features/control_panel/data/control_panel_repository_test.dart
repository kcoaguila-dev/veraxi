import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/features/control_panel/data/control_panel_repository.dart';

void main() {
  group('ControlPanelRepository.fetchStats', () {
    test('sends a GET request and returns the decoded stats', () async {
      late http.Request capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
            jsonEncode({'node_count': 3, 'vector_count': 8}), 200);
      });

      final repository = ControlPanelRepository(client: mockClient);
      final result = await repository.fetchStats();

      expect(result, {'node_count': 3, 'vector_count': 8});
      expect(capturedRequest.method, 'GET');
      expect(capturedRequest.url.toString(),
          'http://localhost:8000/api/admin/stats');
      expect(capturedRequest.headers.containsKey('Authorization'), isFalse);
    });

    test('adds an Authorization header when a tenantId is provided',
        () async {
      late http.Request capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({}), 200);
      });

      final repository =
          ControlPanelRepository(client: mockClient, tenantId: 'tenant-1');
      await repository.fetchStats();

      expect(capturedRequest.headers['Authorization'], 'Bearer tenant-1');
    });

    test('throws an exception with the status code on non-200 responses',
        () async {
      final mockClient =
          MockClient((request) async => http.Response('oops', 503));
      final repository = ControlPanelRepository(client: mockClient);

      await expectLater(
        repository.fetchStats(),
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
      final mockClient = MockClient((request) async {
        throw const SocketException('Failed host lookup');
      });
      final repository = ControlPanelRepository(client: mockClient);

      await expectLater(
        repository.fetchStats(),
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
      final mockClient = MockClient((request) async {
        throw TimeoutException('too slow');
      });
      final repository = ControlPanelRepository(client: mockClient);

      await expectLater(
        repository.fetchStats(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Connection timeout: Server took too long to respond.'),
          ),
        ),
      );
    });
  });

  group('ControlPanelRepository.triggerIngestion', () {
    test('sends a POST request with the text body and returns the result',
        () async {
      late http.Request capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(
            jsonEncode({'nodes_inserted': 2, 'vectors_inserted': 4}), 200);
      });

      final repository = ControlPanelRepository(client: mockClient);
      final result = await repository.triggerIngestion('some text');

      expect(result, {'nodes_inserted': 2, 'vectors_inserted': 4});
      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.toString(),
          'http://localhost:8000/api/admin/ingest');
      expect(capturedRequest.headers['Content-Type'], 'application/json');
      expect(jsonDecode(capturedRequest.body), {'text': 'some text'});
    });

    test('adds an Authorization header when a tenantId is provided',
        () async {
      late http.Request capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({}), 200);
      });

      final repository =
          ControlPanelRepository(client: mockClient, tenantId: 'tenant-9');
      await repository.triggerIngestion('some text');

      expect(capturedRequest.headers['Authorization'], 'Bearer tenant-9');
    });

    test('throws an exception with the status code on non-200 responses',
        () async {
      final mockClient =
          MockClient((request) async => http.Response('oops', 400));
      final repository = ControlPanelRepository(client: mockClient);

      await expectLater(
        repository.triggerIngestion('some text'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Server error: 400'),
          ),
        ),
      );
    });

    test('translates SocketException into a friendly network error',
        () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('Failed host lookup');
      });
      final repository = ControlPanelRepository(client: mockClient);

      await expectLater(
        repository.triggerIngestion('some text'),
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
      final mockClient = MockClient((request) async {
        throw TimeoutException('too slow');
      });
      final repository = ControlPanelRepository(client: mockClient);

      await expectLater(
        repository.triggerIngestion('some text'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Connection timeout: Server took too long to respond.'),
          ),
        ),
      );
    });
  });
}