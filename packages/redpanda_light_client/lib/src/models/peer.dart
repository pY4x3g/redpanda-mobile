import 'package:equatable/equatable.dart';
import 'key_pair.dart';
import 'node_id.dart';

/// Represents a remote node (Peer) in the RedPanda network.
class Peer extends Equatable {
  final NodeId nodeId;
  final String ip;
  final int port;
  final KeyPair? keys; // Known keys for this peer

  // Connection metadata
  final bool isConnected;
  final DateTime? lastSeen;

  const Peer({
    required this.nodeId,
    required this.ip,
    required this.port,
    this.keys,
    this.isConnected = false,
    this.lastSeen,
  });

  Peer copyWith({
    NodeId? nodeId,
    String? ip,
    int? port,
    KeyPair? keys,
    bool? isConnected,
    DateTime? lastSeen,
  }) {
    return Peer(
      nodeId: nodeId ?? this.nodeId,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      keys: keys ?? this.keys,
      isConnected: isConnected ?? this.isConnected,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  List<Object?> get props => [nodeId, ip, port, keys, isConnected, lastSeen];
}
