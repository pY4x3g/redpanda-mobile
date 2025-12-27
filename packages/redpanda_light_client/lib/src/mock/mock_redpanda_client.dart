import 'dart:async';
import 'package:redpanda_light_client/src/client_facade.dart';
import 'package:redpanda_light_client/src/models/connection_status.dart';

/// A mock implementation of [RedPandaClient] for testing and UI development.
class MockRedPandaClient implements RedPandaClient {
  final _connectionStatusController = StreamController<ConnectionStatus>.broadcast();
  
  @override
  Stream<ConnectionStatus> get connectionStatus => _connectionStatusController.stream;

  @override
  Future<void> connect() async {
    _connectionStatusController.add(ConnectionStatus.connecting);
    await Future.delayed(const Duration(seconds: 3)); // Simulate network delay
    _connectionStatusController.add(ConnectionStatus.connected);
  }

  @override
  Future<void> disconnect() async {
    _connectionStatusController.add(ConnectionStatus.disconnected);
  }

  @override
  Future<String> sendMessage(String recipientPublicKey, String content) async {
    // Simulate sending
    await Future.delayed(Duration(milliseconds: 500));
    return "mock-message-id-${DateTime.now().millisecondsSinceEpoch}";
  }
}
