# RedPanda Light Client

A lightweight, P2P networking library for Dart/Flutter, implementing the RedPanda protocol. This client is optimized for mobile environments, providing essential connectivity and messaging features without the overhead of a full node.

## 📦 Features

- **Decentralized Communication**: Direct TCP socket connections between peers.
- **Protocol Buffers**: Type-safe command serialization using Protobuf.
- **End-to-End Encryption**: 
  - ECC Key Pair generation.
  - Diffie-Hellman Shared Secret derivation.
  - Robust handshake state machine with handling for out-of-order encryption activation.
- **Smart Peer Discovery**: Kademlia-inspired peer exchange (`SEND_PEERLIST`).
- **Resilient Connection Management**:
  - Background connection/reconnection routine.
  - DNS-based peer deduplication to prevent redundant socket connections.
  - Support for multiple seed nodes.

## 🛠 Usage

### Initialization

```dart
final keys = KeyPair.generate();
final selfNodeId = NodeId.fromPublicKey(keys);

final client = RedPandaLightClient(
  selfNodeId: selfNodeId,
  selfKeys: keys,
  seeds: ['seed1.redpanda.im:59558', 'seed2.redpanda.im:59558'],
);

await client.connect();
```

### Listening for Status

```dart
client.connectionStatus.listen((status) {
  print('Connection Status: $status');
});

client.peerCountStream.listen((count) {
  print('Connected Peers: $count');
});
```

### Adding Peers

```dart
await client.addPeer('another-node.com:59558');
```

## 🏗 Architecture

The client follows a facade-based architecture:
- `RedPandaClient`: The public interface.
- `RedPandaLightClient`: The main implementation managing the peer pool.
- `ActivePeer`: Handles individual TCP connections, framing, and encryption status.
- `EncryptionManager`: Manages cryptographic handshakes and packet encryption/decryption.

## 🔬 Testing

The package includes a comprehensive unit and E2E test suite. E2E tests can interact with a local Java-based RedPanda full node launcher.

```bash
flutter test
```

---
Part of the [RedPanda ecosystem](https://github.com/redPanda-project).
