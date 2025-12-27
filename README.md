# RedPanda Mobile

RedPanda Mobile is a decentralized, peer-to-peer (P2P) messaging application for iOS and Android, built with Flutter. It implements the RedPanda protocol, allowing for secure, encrypted communication without relying on central servers.

## 🚀 Project Overview

The project consists of a Flutter application and a specialized `redpanda_light_client` Dart package designed for mobile devices. It communicates with the RedPanda network through a custom TCP-based protocol, featuring Kademlia-inspired peer discovery and end-to-end encryption.

### Key Components

- **Mobile App (`/lib`)**: The Flutter frontend, providing a modern chat UI and state management.
- **Light Client (`/packages/redpanda_light_client`)**: A standalone Dart package that handles the P2P networking, protocol framing, and cryptographic operations.
- **Protocol Buffer Definitions**: Standardized message formats for cross-platform compatibility with other RedPanda nodes (e.g., the Java Full Node).

## ✨ Current Status & Features

The project is currently in active development. Recent achievements include:

- [x] **Protobuf Integration**: Fully functional command serialization/deserialization.
- [x] **Encryption Handshake**: Secure ECC-based handshake with shared secret derivation (using `pointycastle`).
- [x] **Protocol Robustness**: Fixed race conditions in the encryption activation sequence and implemented connection deduplication (IP/DNS-based).
- [x] **Peer Discovery**: Automatic peer list exchange and connection management.
- [x] **iOS Simulator Verified**: Successfully running and connecting from the iOS 16e simulator.
- [x] **UI Progress**: Real-time connection status badge with peer count tracking.

## 🛠 Tech Stack

- **Frontend**: Flutter / Dart
- **Networking**: TCP Sockets (`dart:io`)
- **Cryptography**: PointyCastle (ECC, SHA-256)
- **Serialization**: Protocol Buffers (Protobuf)
- **State Management**: Riverpod (Providers)

## 📦 Getting Started

### Prerequisites

- Flutter SDK (latest stable)
- Java 21+ (if running the reference full node locally)
- Protobuf compiler (`protoc`) and Dart plugin (for protocol changes)

### Setup

1. **Clone the repository**:
   ```bash
   git clone git@github.com:pY4x3g/redpanda-mobile.git
   cd redpanda-mobile
   ```

2. **Install dependencies**:
   ```bash
   flutter pub get
   cd packages/redpanda_light_client
   flutter pub get
   cd ../..
   ```

3. **Run the app**:
   ```bash
   flutter run
   ```

## 🧪 Testing

The project follows a test-driven approach. You can run unit and E2E tests for the light client:

```bash
cd packages/redpanda_light_client
flutter test
```

## 🗺 Roadmap

- [ ] Private Channel Implementation (QR-based key sharing).
- [ ] Message Persistence (Local Database).
- [ ] Multi-device synchronization.
- [ ] Enhanced Kademlia routing for mobile peers.

---
**RedPanda Project** - *Secure, Private, Decentralized.*
