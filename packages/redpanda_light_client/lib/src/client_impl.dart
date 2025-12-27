import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';
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
  static const int PING = 5;
  static const int PONG = 6;

  final List<String> seeds;
  Socket? _socket;
  final List<int> _buffer = []; 
  
  // State
  bool _handshakeVerified = false;
  bool _publicKeySent = false;
  Future<void>? _handshakeInitiationFuture;
  
  final EncryptionManager _encryptionManager = EncryptionManager();
  
  bool get isEncryptionActive => _encryptionManager.isEncryptionActive;
  bool get isPongSent => _pongSent;

  ECPublicKey? _peerPublicKey;
  Uint8List? _randomFromUs;
  bool _pongSent = false;

  RedPandaLightClient({
    required this.selfNodeId,
    required this.selfKeys,
    this.seeds = defaultSeeds,
  });

  @override
  Stream<ConnectionStatus> get connectionStatus async* {
    yield _currentStatus;
    yield* _connectionStatusController.stream;
  }

  void _updateStatus(ConnectionStatus status) {
    _currentStatus = status;
    _connectionStatusController.add(status);
  }

  @override
  Future<void> connect() async {
    _updateStatus(ConnectionStatus.connecting);
    print('RedPandaLightClient: Connecting to network via seeds: $seeds');

    if (seeds.isEmpty) {
      _updateStatus(ConnectionStatus.disconnected);
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
          _updateStatus(ConnectionStatus.disconnected);
        },
        onDone: () {
          print('RedPandaLightClient socket closed');
          _updateStatus(ConnectionStatus.disconnected);
        },
      );

    } catch (e) {
      print('RedPandaLightClient connection failed: $e');
      _updateStatus(ConnectionStatus.disconnected);
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

  bool _isProcessingBuffer = false;
  ConnectionStatus _currentStatus = ConnectionStatus.disconnected;

  void _handleSocketData(Uint8List data) {
    // 1. Decrypt if needed
    var processData = data;
    if (_encryptionManager.isEncryptionActive) {
      processData = _encryptionManager.decrypt(data);
    }
    _buffer.addAll(processData);
    print('RedPandaLightClient received: ${data.length} bytes (Decrypted: $isEncryptionActive). Total buffer: ${_buffer.length}');
    
    // 2. Trigger processing loop if not already running
    if (!_isProcessingBuffer) {
      _processBuffer();
    }
  }

  Future<void> _processBuffer() async {
    if (_isProcessingBuffer) return; // Prevention
    _isProcessingBuffer = true;

    try {
      while (true) {
        if (_buffer.isEmpty) break;

        if (!_handshakeVerified) {
          if (_buffer.length >= HANDSHAKE_LENGTH) {
            _processHandshake();
            continue; 
          } else {
            break; // Need more data
          }
        } else {
          // Handshake verified, process commands
          final command = _buffer[0];
          
          if (command == REQUEST_PUBLIC_KEY) {
            print('RedPandaLightClient: Received REQUEST_PUBLIC_KEY');
            _buffer.removeAt(0); 
            _sendPublicKey();
          } else if (command == ACTIVATE_ENCRYPTION) {
            print('RedPandaLightClient: Received ACTIVATE_ENCRYPTION');
            if (_buffer.length < 1 + 8) {
              print('RedPandaLightClient: Waiting for random bytes...');
              break; 
            }

            // Await our handshake initiation IF it exists
            if (_handshakeInitiationFuture != null) {
              await _handshakeInitiationFuture;
            }

            _buffer.removeAt(0); 
            final randomFromThem = _buffer.sublist(0, 8);
            _buffer.removeRange(0, 8); // remove bytes
            
            await _handlePeerEncryptionRandom(Uint8List.fromList(randomFromThem));
          } else if (command == SEND_PUBLIC_KEY) {
            print('RedPandaLightClient: Received SEND_PUBLIC_KEY');
            if (_buffer.length < 1 + 65) {
               print('RedPandaLightClient: Waiting for Public Key bytes...');
               break; 
            }
            _buffer.removeAt(0); 
            final keyBytes = _buffer.sublist(0, 65);
            _buffer.removeRange(0, 65);
            
            _parsePeerPublicKey(keyBytes);
          } else if (command == PING) {
            print('RedPandaLightClient: Received PING (Encrypted). Sending PONG...');
            _buffer.removeAt(0); 
            _sendPong();
          } else if (command == PONG) {
            print('RedPandaLightClient: Received PONG (Encrypted).');
            _buffer.removeAt(0);
          } else {
             // Unknown command
             print('RedPandaLightClient: Unknown command byte: $command. Discarding byte to prevent loop.');
             _buffer.removeAt(0);
             // Alternatively, we could break or disconnect, but consuming ensures we don't loop forever.
          }
        }
      }
    } catch (e, stack) {
      print('RedPandaLightClient: Error processing buffer: $e');
      print(stack);
    } finally {
      _isProcessingBuffer = false;
      // If data arrived while we were awaiting (e.g. handshake future), check if we need to run again?
      // Actually, since we append to _buffer synchronously in _handleSocketData,
      // and we just finished the loop which checks _buffer.isEmpty, we should be good.
      // BUT if we awaited _handshakeInitiationFuture, new data might have arrived and added to _buffer,
      // AND we might have exited the loop or not. 
      // If we are in the loop, we continue processing.
      // If we broke out of loop (e.g. need more data), and new data arrived, _handleSocketData would see _isProcessingBuffer=true and return.
      // So we need to re-check buffer at end? 
      // A better pattern is:
      // while(buffer has data) { ... }
      // But _handleSocketData adds data.
      // If _ProcessBuffer exits while data is there (unlikely unless waiting for bytes), it's fine.
      // If it exits because waiting for future? No, await pauses execution, doesn't exit function.
      
      // Edge case: _handleSocketData adds data while _processBuffer is at 'await'.
      // _processBuffer resumes. It sees new data in _buffer (since it's same list object).
      // So it continues.
      
      // Edge case: _processBuffer finishes loop (break needs more data). Sets flag false.
      // _handleSocketData adds new data -> calls _processBuffer. Correct.
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
          _handshakeInitiationFuture = _initiateEncryptionHandshake();
      }
  }

  Future<void> _initiateEncryptionHandshake() async {
      print('RedPandaLightClient: Initiating Encryption Handshake...');
      _randomFromUs = _encryptionManager.generateRandomFromUs();
      
      // Separate packet to avoid server buffering issues
      await Future.delayed(const Duration(milliseconds: 100));

      final buffer = BytesBuilder();
      buffer.addByte(ACTIVATE_ENCRYPTION);
      buffer.add(_randomFromUs!);
      _sendData(buffer.toBytes(), forceUnencrypted: true); // MUST be unencrypted
      print('RedPandaLightClient: Sent ACTIVATE_ENCRYPTION request.');
  }

  Future<void> _handlePeerEncryptionRandom(Uint8List randomFromThem) async {
     if (_randomFromUs == null) {
        // We received random from peer but haven't sent ours yet (Server initiated?)
        // Send ours now.
        _handshakeInitiationFuture = _initiateEncryptionHandshake();
        await _handshakeInitiationFuture;
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
      
      // The server expects PING as the first encrypted command to verify the channel.
      print('RedPandaLightClient: Sending Initial PING (Encrypted) to verify handshake...');
      _sendData([PING]);
      
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
      _updateStatus(ConnectionStatus.connected);
      
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

  void _sendPong() {
    print('RedPandaLightClient: Sending PONG...');
    _sendData([PONG]);
    _pongSent = true;
  }



  void _sendData(List<int> data, {bool forceUnencrypted = false}) {
    if (_socket == null) return;
    
    Uint8List output;
    if (_encryptionManager.isEncryptionActive && !forceUnencrypted) {
      output = _encryptionManager.encrypt(Uint8List.fromList(data));
    } else {
      output = Uint8List.fromList(data);
    }
    
    _socket!.add(output);
  }

  

  @override
  Future<void> disconnect() async {
    // TODO: Graceful shutdown
    _updateStatus(ConnectionStatus.disconnected);
  }

  @override
  Future<String> sendMessage(String recipientPublicKey, String content) async {
    // TODO: Implement Garlic Routing / Flaschenpost
    throw UnimplementedError("sendMessage not implemented in RealRedPandaClient yet");
  }
}
