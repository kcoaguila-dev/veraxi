import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:veraxi_app/features/chat/data/chat_repository.dart';

void main() {
  group('ChatRepository.sendMessage', () {
    test('sends a POST request with the question and returns the answer',
        () async {
      late http.Request capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'answer': 'Hello back'}), 200);
      });

      final repository = ChatRepository(client: mockClient);
      final answer = await repository.sendMessage('Hi there');

      expect(answer, 'Hello back');
      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.toString(),
          'http://localhost:8000/api/chat');
      expect(capturedRequest.headers['Content-Type'], 'application/json');
      expect(capturedRequest.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(capturedRequest.body), {'question': 'Hi there'});
    });

    test('adds an Authorization header when a tenantId is provided',
        () async {
      late http.Request capturedRequest;
      final mockClient = MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode({'answer': 'ok'}), 200);
      });

      final repository =
          ChatRepository(client: mockClient, tenantId: 'tenant-123');
      await repository.sendMessage('hi');

      expect(capturedRequest.headers['Authorization'], 'Bearer tenant-123');
    });

    test('throws an exception with the status code on non-200 responses',
        () async {
      final mockClient =
          MockClient((request) async => http.Response('oops', 500));
      final repository = ChatRepository(client: mockClient);

      await expectLater(
        repository.sendMessage('hi'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Server error: 500'),
          ),
        ),
      );
    });

    test('translates SocketException into a friendly network error',
        () async {
      final mockClient = MockClient((request) async {
        throw const SocketException('Failed host lookup');
      });
      final repository = ChatRepository(client: mockClient);

      await expectLater(
        repository.sendMessage('hi'),
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
      final repository = ChatRepository(client: mockClient);

      await expectLater(
        repository.sendMessage('hi'),
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
      final mockClient = MockClient((request) async {
        throw const FormatException('bad data');
      });
      final repository = ChatRepository(client: mockClient);

      await expectLater(
        repository.sendMessage('hi'),
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