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
/// Factory for creating sockets (allows mocking).
typedef SocketFactory = Future<Socket> Function(String host, int port);

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

  final SocketFactory _socketFactory;
  final Set<String> _knownAddresses = {};
  final Map<String, ActivePeer> _peers = {};
  Timer? _connectionTimer;
  ConnectionStatus _currentStatus = ConnectionStatus.disconnected;

  bool get isEncryptionActive => _peers.values.any((p) => p.isEncryptionActive);
  bool get isPongSent => _peers.values.any((p) => p.isPongSent);

  RedPandaLightClient({
    required this.selfNodeId,
    required this.selfKeys,
    List<String> seeds = defaultSeeds,
    SocketFactory? socketFactory,
  }) : _socketFactory = socketFactory ?? ((h, p) => Socket.connect(h, p)) {
    _knownAddresses.addAll(seeds);
  }

  @override
  Stream<ConnectionStatus> get connectionStatus async* {
    yield _currentStatus;
    yield* _connectionStatusController.stream;
  }
  
  void _updateStatus(ConnectionStatus status) {
    // Simple aggregation: If ANY connected -> Connected.
    // If ALL disconnected -> Disconnected.
    // Logic:
    // If incoming status is connected -> set global connected.
    // If incoming is disconnected -> Check if others are connected.
    
    if (status == ConnectionStatus.connected) {
      if (_currentStatus != ConnectionStatus.connected) {
        _currentStatus = ConnectionStatus.connected;
        _connectionStatusController.add(ConnectionStatus.connected);
      }
    } else {
      // Check if any peer is connected
      bool anyConnected = _peers.values.any((p) => p.isHandshakeVerified);
      if (!anyConnected && _currentStatus != ConnectionStatus.disconnected) {
        _currentStatus = ConnectionStatus.disconnected;
        _connectionStatusController.add(ConnectionStatus.disconnected);
      }
    }
  }

  @override
  Future<void> connect() async {
    _updateStatus(ConnectionStatus.connecting);
    print('RedPandaLightClient: Starting connection routine...');
    
    _startConnectionRoutine();
  }

  void _startConnectionRoutine() {
    _runConnectionCheck();
    _connectionTimer?.cancel();
    _connectionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _runConnectionCheck();
    });
  }

  Future<void> _runConnectionCheck() async {
    print('RedPandaLightClient: Running connection check on ${_knownAddresses.length} addresses.');
    for (final address in _knownAddresses) {
      if (_peers.containsKey(address)) {
        final peer = _peers[address]!;
        if (peer.isDisconnected) {
          print('RedPandaLightClient: Peer $address is disconnected. Retrying...');
          _peers.remove(address);
        } else {
          continue; // Already connected or connecting
        }
      }

      // Start new connection
      try {
        final peer = ActivePeer(
          address: address,
          selfNodeId: selfNodeId,
          selfKeys: selfKeys,
          socketFactory: _socketFactory,
          onStatusChange: _updateStatus,
          onDisconnect: () {
             // Peer calls this when socket closes
             // We don't remove immediately, routine will clean up
          },
        );
        _peers[address] = peer;
        peer.connect(); // Fire and forget (it is async inside)
      } catch (e) {
        print('RedPandaLightClient: Failed to initiate peer $address: $e');
      }
    }
  }

  @override
  void addPeer(String address) {
    if (!_knownAddresses.contains(address)) {
      print('RedPandaLightClient: Adding new peer $address');
      _knownAddresses.add(address);
      // Optional: trigger immediate check?
      // For now wait for next tick or logic flow
    }
  }

  @override
  Future<void> disconnect() async {
    _connectionTimer?.cancel();
    for (final peer in _peers.values) {
      await peer.disconnect();
    }
    _peers.clear();
    _updateStatus(ConnectionStatus.disconnected);
  }

  @override
  Future<String> sendMessage(String recipientPublicKey, String content) async {
    // TODO: Implement Garlic Routing / Flaschenpost
    throw UnimplementedError("sendMessage not implemented in RealRedPandaClient yet");
  }
}

/// Represents a single active connection attempt or established connection.
class ActivePeer {
  static const String MAGIC = "k3gV";
  static const int PROTOCOL_VERSION = 22;
  static const int HANDSHAKE_LENGTH = 30;

  // Commands
  static const int REQUEST_PUBLIC_KEY = 1;
  static const int SEND_PUBLIC_KEY = 2;
  static const int ACTIVATE_ENCRYPTION = 3;
  static const int PING = 5;
  static const int PONG = 6;

  final String address;
  final NodeId selfNodeId;
  final KeyPair selfKeys;
  final SocketFactory socketFactory;
  final void Function(ConnectionStatus) onStatusChange;
  final void Function() onDisconnect;

  Socket? _socket;
  final List<int> _buffer = []; 
  
  // State
  bool _handshakeVerified = false;
  bool _publicKeySent = false;
  Future<void>? _handshakeInitiationFuture;
  
  final EncryptionManager _encryptionManager = EncryptionManager();
  
  bool get isEncryptionActive => _encryptionManager.isEncryptionActive;
  bool get isPongSent => _pongSent;
  bool get isHandshakeVerified => _handshakeVerified;
  bool get isDisconnected => _socket == null && _isDisconnecting;
  bool _isDisconnecting = false; // Flag if we are logically disconnected

  ECPublicKey? _peerPublicKey;
  Uint8List? _randomFromUs;
  bool _pongSent = false;
  bool _isProcessingBuffer = false;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  ActivePeer({
    required this.address,
    required this.selfNodeId,
    required this.selfKeys,
    required this.socketFactory,
    required this.onStatusChange,
    required this.onDisconnect,
  });

  Future<void> connect() async {
    try {
      final parts = address.split(':');
      final host = parts[0];
      final port = int.parse(parts[1]);

      print('ActivePeer($address): Connecting...');
      final socket = await socketFactory(host, port);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      
      print('ActivePeer($address): TCP Connected. Sending Handshake...');
      _sendHandshake();
      
      _socket!.listen(
        _handleSocketData,
        onError: (e) {
          print('ActivePeer($address) socket error: $e');
          _shutdown();
        },
        onDone: () {
          print('ActivePeer($address) socket closed');
          _shutdown();
        },
      );
    } catch (e) {
      print('ActivePeer($address) connection failed: $e');
      _shutdown();
    }
  }

  void _shutdown() {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    _socket?.destroy(); // or close
    _socket = null;
    _status = ConnectionStatus.disconnected;
    onStatusChange(ConnectionStatus.connected); // Trigger update check (will see disconnected)
    onDisconnect();
  }

  Future<void> disconnect() async {
    _shutdown();
  }

  void _sendHandshake() {
     final buffer = BytesBuilder();
     buffer.add(MAGIC.codeUnits);
     buffer.addByte(PROTOCOL_VERSION);
     buffer.addByte(0xFF); 
     buffer.add(selfNodeId.bytes);
     final portData = ByteData(4);
     portData.setInt32(0, 0, Endian.big); 
     buffer.add(portData.buffer.asUint8List());
     
     _socket!.add(buffer.toBytes());
     print('ActivePeer($address): Handshake sent (${buffer.length} bytes)');
  }

  void _handleSocketData(Uint8List data) {
    var processData = data;
    if (_encryptionManager.isEncryptionActive) {
      processData = _encryptionManager.decrypt(data);
    }
    _buffer.addAll(processData);
    // print('ActivePeer($address) received: ${data.length} bytes. Buffer: ${_buffer.length}');
    
    if (!_isProcessingBuffer) {
      _processBuffer();
    }
  }

  Future<void> _processBuffer() async {
    if (_isProcessingBuffer) return;
    _isProcessingBuffer = true;

    try {
      while (true) {
        if (_buffer.isEmpty) break;

        if (!_handshakeVerified) {
          if (_buffer.length >= HANDSHAKE_LENGTH) {
            _processHandshake();
            continue; 
          } else {
            break; 
          }
        } else {
          final command = _buffer[0];
          
          if (command == REQUEST_PUBLIC_KEY) {
            print('ActivePeer($address): Received REQUEST_PUBLIC_KEY');
            _buffer.removeAt(0); 
            _sendPublicKey();
          } else if (command == ACTIVATE_ENCRYPTION) {
            print('ActivePeer($address): Received ACTIVATE_ENCRYPTION');
            if (_buffer.length < 1 + 8) {
              break; 
            }

            if (_handshakeInitiationFuture != null) {
              await _handshakeInitiationFuture;
            }

            _buffer.removeAt(0); 
            final randomFromThem = _buffer.sublist(0, 8);
            _buffer.removeRange(0, 8); 
            
            await _handlePeerEncryptionRandom(Uint8List.fromList(randomFromThem));
          } else if (command == SEND_PUBLIC_KEY) {
            print('ActivePeer($address): Received SEND_PUBLIC_KEY');
            if (_buffer.length < 1 + 65) {
               break; 
            }
            _buffer.removeAt(0); 
            final keyBytes = _buffer.sublist(0, 65);
            _buffer.removeRange(0, 65);
            
            _parsePeerPublicKey(keyBytes);
          } else if (command == PING) {
            print('ActivePeer($address): Received PING (Encrypted). Sending PONG...');
            _buffer.removeAt(0); 
            _sendPong();
          } else if (command == PONG) {
            print('ActivePeer($address): Received PONG (Encrypted).');
            _buffer.removeAt(0);
          } else {
             print('ActivePeer($address): Unknown command byte: $command. Discarding.');
             _buffer.removeAt(0);
          }
        }
      }
    } catch (e, stack) {
      print('ActivePeer($address): Error processing buffer: $e');
      print(stack);
      _shutdown();
    } finally {
      _isProcessingBuffer = false;
    }
  }

  void _processHandshake() {
      final magicBytes = _buffer.sublist(0, 4);
      final magic = String.fromCharCodes(magicBytes);
      if (magic != MAGIC) {
        print('ActivePeer($address): Invalid Magic. Disconnecting.');
        _shutdown();
        return;
      }
      
      print('ActivePeer($address): Handshake Verified.');
      _handshakeVerified = true;
      onStatusChange(ConnectionStatus.connected); // Notify manager
      
      _buffer.removeRange(0, HANDSHAKE_LENGTH);
      
      print('ActivePeer($address): Requesting Peer Public Key...');
      _socket!.add([REQUEST_PUBLIC_KEY]);
  }

  void _sendPublicKey() {
    print('ActivePeer($address): Sending Public Key...');
    final buffer = BytesBuilder();
    buffer.addByte(SEND_PUBLIC_KEY);
    buffer.add(selfKeys.publicKeyBytes);
    _sendData(buffer.toBytes());
    _publicKeySent = true;
  }

  void _parsePeerPublicKey(List<int> keyBytes) {
      final ecParams = ECDomainParameters('brainpoolp256r1');
      final curve = ecParams.curve;
      final point = curve.decodePoint(keyBytes);
      _peerPublicKey = ECPublicKey(point, ecParams);
      print('ActivePeer($address): Peer Public Key Parsed.');
      
      if (_randomFromUs == null) {
          _handshakeInitiationFuture = _initiateEncryptionHandshake();
      }
  }

  Future<void> _initiateEncryptionHandshake() async {
      print('ActivePeer($address): Initiating Encryption Handshake...');
      _randomFromUs = _encryptionManager.generateRandomFromUs();
      await Future.delayed(const Duration(milliseconds: 100)); // Buffer anti-glitch
      final buffer = BytesBuilder();
      buffer.addByte(ACTIVATE_ENCRYPTION);
      buffer.add(_randomFromUs!);
      _sendData(buffer.toBytes(), forceUnencrypted: true); 
      print('ActivePeer($address): Sent ACTIVATE_ENCRYPTION request.');
  }

  Future<void> _handlePeerEncryptionRandom(Uint8List randomFromThem) async {
     if (_randomFromUs == null) {
        _handshakeInitiationFuture = _initiateEncryptionHandshake();
        await _handshakeInitiationFuture;
     }
     _finalizeEncryption(randomFromThem);
  }

  void _finalizeEncryption(Uint8List randomFromThem) {
    try {
      if (selfKeys.privateKey == null || _peerPublicKey == null || _randomFromUs == null) {
        print('ActivePeer($address): Cannot activate encryption, missing state.');
        return;
      }

      print('ActivePeer($address): Finalizing Encryption...');
      _encryptionManager.deriveAndInitialize(
        selfKeys: selfKeys.asAsymmetricKeyPair(), 
        peerPublicKey: _peerPublicKey!, 
        randomFromUs: _randomFromUs!, 
        randomFromThem: randomFromThem
      );
      
      print('ActivePeer($address): Encryption Active!');
      print('ActivePeer($address): Sending Initial PING (Encrypted)...');
      _sendData([PING]);
      
      if (_buffer.isNotEmpty) {
          final remaining = Uint8List.fromList(_buffer);
          _buffer.clear();
          final decrypted = _encryptionManager.decrypt(remaining);
          _buffer.addAll(decrypted);
          print('ActivePeer($address): Decrypted residual bytes.');
      }
    } catch (e, stack) {
      print('ActivePeer($address): Error activating encryption: $e');
      print(stack);
      _shutdown();
    }
  }

  void _sendPong() {
    print('ActivePeer($address): Sending PONG...');
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
}
