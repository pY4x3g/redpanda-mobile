import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/ecc/api.dart'; // Needed for ECPublicKey field

import 'package:redpanda_light_client/src/security/encryption_manager.dart';

import 'package:redpanda_light_client/src/client_facade.dart';
import 'package:redpanda_light_client/src/models/connection_status.dart';
import 'package:redpanda_light_client/src/models/key_pair.dart';
import 'package:redpanda_light_client/src/models/node_id.dart';

/// The implementation of the RedPanda Light Client.
/// Manages network connections, encryption, and routing.
class RedPandaLightClient implements RedPandaClient {
  final NodeId selfNodeId;
  final KeyPair selfKeys;
  
  // TODO: Inject NetworkManager/ConnectionManager
  // final NetworkManager _networkManager;

  final _connectionStatusController = StreamController<ConnectionStatus>.broadcast();

  static const List<String> defaultSeeds = [
    'localhost:59558',
    'localhost:59559',
  ];

  static const String MAGIC = "k3gV";
  static const int PROTOCOL_VERSION = 22;
  static const int HANDSHAKE_LENGTH = 30;

  // Commands
  static const int REQUEST_PUBLIC_KEY = 1;
  static const int SEND_PUBLIC_KEY = 2;
  static const int ACTIVATE_ENCRYPTION = 3;

  final List<String> seeds;
  Socket? _socket;
  final List<int> _buffer = []; 
  
  // State
  bool _handshakeVerified = false;
  bool _publicKeySent = false;
  
  final EncryptionManager _encryptionManager = EncryptionManager();
  
  bool get isEncryptionActive => _encryptionManager.isEncryptionActive;

  ECPublicKey? _peerPublicKey;
  Uint8List? _randomFromUs;

  RedPandaLightClient({
    required this.selfNodeId,
    required this.selfKeys,
    this.seeds = defaultSeeds,
  });

  @override
  Stream<ConnectionStatus> get connectionStatus => _connectionStatusController.stream;

  @override
  Future<void> connect() async {
    _connectionStatusController.add(ConnectionStatus.connecting);
    print('RedPandaLightClient: Connecting to network via seeds: $seeds');

    if (seeds.isEmpty) {
      _connectionStatusController.add(ConnectionStatus.disconnected);
      return;
    }

    try {
      final seedParts = seeds[0].split(':');
      final host = seedParts[0];
      final port = int.parse(seedParts[1]);

      print('RedPandaLightClient: Connecting to $host:$port...');
      final socket = await Socket.connect(host, port);
      socket.setOption(SocketOption.tcpNoDelay, true); // Mitigate server buffering bugs
      _socket = socket;
      
      print('RedPandaLightClient: TCP Connected. Sending Handshake...');
      _sendHandshake();
      
      _socket!.listen(
        _handleSocketData,
        onError: (e) {
          print('RedPandaLightClient socket error: $e');
          _connectionStatusController.add(ConnectionStatus.disconnected);
        },
        onDone: () {
          print('RedPandaLightClient socket closed');
          _connectionStatusController.add(ConnectionStatus.disconnected);
        },
      );

    } catch (e) {
      print('RedPandaLightClient connection failed: $e');
      _connectionStatusController.add(ConnectionStatus.disconnected);
      rethrow;
    }
  }

  void _sendHandshake() {
     // Format: [MAGIC (4)][VERSION (1)][TYPE (1)][NODE_ID (20)][PORT (4)]
     final buffer = BytesBuilder();
     
     // Magic
     buffer.add(MAGIC.codeUnits);
     
     // Version
     buffer.addByte(PROTOCOL_VERSION);
     
     // Type: Light Client (0xFF / 255)
     // Based on Java: if (clientType > 128 || clientType < 0) -> LightClient
     buffer.addByte(0xFF); 
     
     // Node ID (20 bytes)
     buffer.add(selfNodeId.bytes);
     
     // Port (4 bytes int) - We are not listening, so send 0? Or 50000? 
     // Java checks port < 0 || port > 65535.
     // Let's send 0.
     final portData = ByteData(4);
     portData.setInt32(0, 0, Endian.big); // Java uses ByteBuffer defaults to BIG_ENDIAN
     buffer.add(portData.buffer.asUint8List());
     
     _socket!.add(buffer.toBytes());
     print('RedPandaLightClient: Handshake sent (${buffer.length} bytes)');
  }

  void _handleSocketData(Uint8List data) {
    var processData = data;
    
    if (_encryptionManager.isEncryptionActive) {
      // Decrypt incoming data in place (or new buffer)
      processData = _encryptionManager.decrypt(data);
      print('RedPandaLightClient: Decrypted ${data.length} bytes.');
    }

    _buffer.addAll(processData);
    print('RedPandaLightClient received: ${data.length} bytes (Decrypted: $isEncryptionActive). Total buffer: ${_buffer.length}');

    while (true) {
      if (!_handshakeVerified) {
        if (_buffer.length >= HANDSHAKE_LENGTH) {
           _processHandshake();
           continue; // Check if there is more data
        } else {
          break; // Need more data
        }
      } else {
        // Handshake verified, process commands
        if (_buffer.isEmpty) break;

        final command = _buffer[0];
        if (command == REQUEST_PUBLIC_KEY) {
           print('RedPandaLightClient: Received REQUEST_PUBLIC_KEY');
           _buffer.removeAt(0); // Consume command byte
           _sendPublicKey();
        } else if (command == ACTIVATE_ENCRYPTION) {
           print('RedPandaLightClient: Received ACTIVATE_ENCRYPTION');
           if (_buffer.length < 1 + 8) {
             print('RedPandaLightClient: Waiting for random bytes...');
             break; // Need more data (request byte + 8 random bytes)
           }
           _buffer.removeAt(0); // Consume command byte
           
           final randomFromThem = _buffer.sublist(0, 8);
           _buffer.removeRange(0, 8);
           
           _handlePeerEncryptionRandom(Uint8List.fromList(randomFromThem));
        } else if (command == SEND_PUBLIC_KEY) {
           print('RedPandaLightClient: Received SEND_PUBLIC_KEY');
           if (_buffer.length < 1 + 65) {
              print('RedPandaLightClient: Waiting for Public Key bytes...');
              break; 
           }
           _buffer.removeAt(0); // Consume command
           final keyBytes = _buffer.sublist(0, 65);
           _buffer.removeRange(0, 65);
           
           _parsePeerPublicKey(keyBytes);
        } else {
             // ...
        }
      }
    }
  }

  void _parsePeerPublicKey(List<int> keyBytes) {
      // ... parse ...
      final ecParams = ECDomainParameters('brainpoolp256r1');
      final curve = ecParams.curve;
      final point = curve.decodePoint(keyBytes);
      _peerPublicKey = ECPublicKey(point, ecParams);
      print('RedPandaLightClient: Peer Public Key Parsed.');
      
      // Initiate Encryption Handshake if not already done
      if (_randomFromUs == null) {
          _initiateEncryptionHandshake();
      }
  }

  Future<void> _initiateEncryptionHandshake() async {
      print('RedPandaLightClient: Initiating Encryption Handshake...');
      _randomFromUs = _encryptionManager.generateRandomFromUs();
      
      // Workaround: Java Server drops trailing bytes if multiple commands arrive in one packet.
      // We must ensure this is a separate packet.
      await Future.delayed(const Duration(milliseconds: 1000));

      final buffer = BytesBuilder();
      buffer.addByte(ACTIVATE_ENCRYPTION);
      buffer.add(_randomFromUs!);
      _sendData(buffer.toBytes());
      print('RedPandaLightClient: Sent ACTIVATE_ENCRYPTION request.');
  }

  void _handlePeerEncryptionRandom(Uint8List randomFromThem) {
     if (_randomFromUs == null) {
        // We received random from peer but haven't sent ours yet (Server initiated?)
        // Send ours now.
        _initiateEncryptionHandshake();
     }
     
     _finalizeEncryption(randomFromThem);
  }

  void _finalizeEncryption(Uint8List randomFromThem) {
    try {
      if (selfKeys.privateKey == null || _peerPublicKey == null || _randomFromUs == null) {
        print('RedPandaLightClient: Cannot activate encryption, missing state (Key/PeerKey/RandomUs).');
        return;
      }

      print('RedPandaLightClient: Finalizing Encryption...');

      _encryptionManager.deriveAndInitialize(
        selfKeys: selfKeys.asAsymmetricKeyPair(), 
        peerPublicKey: _peerPublicKey!, 
        randomFromUs: _randomFromUs!, 
        randomFromThem: randomFromThem
      );
      
      print('RedPandaLightClient: Encryption Active! Ciphers initialized.');
      
      // Decrypt any remaining bytes in the buffer that arrived with the activation packet
      if (_buffer.isNotEmpty) {
          final remaining = Uint8List.fromList(_buffer);
          _buffer.clear();
          final decrypted = _encryptionManager.decrypt(remaining);
          _buffer.addAll(decrypted);
          print('RedPandaLightClient: Decrypted ${decrypted.length} residual bytes from buffer.');
      }
    } catch (e, stack) {
      print('RedPandaLightClient: Error activating encryption: $e');
      print(stack);
    }
  }

  void _processHandshake() {
      // Check Magic
      final magicBytes = _buffer.sublist(0, 4);
      final magic = String.fromCharCodes(magicBytes);
      if (magic != MAGIC) {
        print('RedPandaLightClient: Invalid Magic: $magic. Disconnecting.');
        _socket!.destroy();
        return;
      }
      
      print('RedPandaLightClient: Handshake Verified.');
      _handshakeVerified = true;
      _connectionStatusController.add(ConnectionStatus.connected);
      
      // Clear handshake from buffer
      _buffer.removeRange(0, HANDSHAKE_LENGTH);
      
      // Immediately request Peer's Public Key
      print('RedPandaLightClient: Requesting Peer Public Key...');
      _socket!.add([REQUEST_PUBLIC_KEY]);
  }

  void _sendPublicKey() {
    print('RedPandaLightClient: Sending Public Key...');
    final buffer = BytesBuilder();
    buffer.addByte(SEND_PUBLIC_KEY);
    buffer.add(selfKeys.publicKeyBytes);
    _sendData(buffer.toBytes());
    _publicKeySent = true;
  }



  void _sendData(List<int> data) {
    if (_socket == null) return;
    
    Uint8List output;
    if (_encryptionManager.isEncryptionActive) {
      output = _encryptionManager.encrypt(Uint8List.fromList(data));
    } else {
      output = Uint8List.fromList(data);
    }
    
    _socket!.add(output);
  }

  

  @override
  Future<void> disconnect() async {
    // TODO: Graceful shutdown
    _connectionStatusController.add(ConnectionStatus.disconnected);
  }

  @override
  Future<String> sendMessage(String recipientPublicKey, String content) async {
    // TODO: Implement Garlic Routing / Flaschenpost
    throw UnimplementedError("sendMessage not implemented in RealRedPandaClient yet");
  }
}
