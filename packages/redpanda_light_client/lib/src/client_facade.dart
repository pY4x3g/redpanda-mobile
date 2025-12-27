import 'package:redpanda_light_client/src/models/connection_status.dart';

/// The primary interface for the App to interact with the RedPanda Network.
abstract class RedPandaClient {
  /// Stream of connection status updates.
  Stream<ConnectionStatus> get connectionStatus;

  /// Connects to the network (starts background services).
  Future<void> connect();

  /// Disconnects from the network.
  Future<void> disconnect();

  /// Sends a message to a public key (hex string).
  /// Returns a message ID.
  Future<String> sendMessage(String recipientPublicKey, String content);
}
