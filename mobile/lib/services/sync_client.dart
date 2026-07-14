import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/device.dart';
import '../models/memo.dart';
import '../models/protocol.dart';
import 'identity.dart';
import 'store.dart';

enum SyncConnectionState {
  disconnected,
  connecting,
  handshaking,
  syncing,
  online,
  error,
}

class SyncStatus {
  const SyncStatus({
    required this.state,
    this.peerName,
    this.message,
    this.pendingOutbound = 0,
  });

  final SyncConnectionState state;
  final String? peerName;
  final String? message;
  final int pendingOutbound;

  SyncStatus copyWith({
    SyncConnectionState? state,
    String? peerName,
    String? message,
    int? pendingOutbound,
  }) {
    return SyncStatus(
      state: state ?? this.state,
      peerName: peerName ?? this.peerName,
      message: message ?? this.message,
      pendingOutbound: pendingOutbound ?? this.pendingOutbound,
    );
  }
}

class SyncClient {
  SyncClient({
    required Store store,
    required IdentityService identity,
  })  : _store = store,
        _identity = identity;

  final Store _store;
  final IdentityService _identity;

  final _statusController = StreamController<SyncStatus>.broadcast();
  final _memoChangedController = StreamController<void>.broadcast();

  Stream<SyncStatus> get statusStream => _statusController.stream;
  Stream<void> get memoChangedStream => _memoChangedController.stream;

  SyncStatus _status = const SyncStatus(state: SyncConnectionState.disconnected);
  Socket? _socket;
  String? _sessionId;
  String? _peerDeviceId;
  String? _sharedSecret;
  Timer? _pingTimer;
  bool _running = false;

  SyncStatus get currentStatus => _status;

  void _emit(SyncStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  Future<void> connectToPeer({
    required String host,
    required int port,
    String? ticket,
    PairingPayload? pairingPayload,
  }) async {
    await disconnect();
    _running = true;
    _emit(const SyncStatus(
      state: SyncConnectionState.connecting,
      message: '正在连接…',
    ));

    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 10));
      _socket = socket;
      await _runHandshake(
        socket: socket,
        ticket: ticket ?? pairingPayload?.ticket,
        expectedPeerId: pairingPayload?.deviceId,
      );
      unawaited(_runReadLoop(socket));
    } catch (e) {
      _emit(SyncStatus(
        state: SyncConnectionState.error,
        message: '连接失败：$e',
      ));
    } finally {
      if (_status.state != SyncConnectionState.online) {
        _running = false;
        await _cleanupSocket();
      }
    }
  }

  Future<void> reconnectLastPeer() async {
    final peers = await _store.listPeers();
    if (peers.isEmpty) return;
    final host = await _store.getMeta('last_host');
    final portStr = await _store.getMeta('last_port');
    if (host == null || portStr == null) return;
    final port = int.tryParse(portStr) ?? defaultPort;
    await connectToPeer(host: host, port: port);
  }

  Future<void> disconnect() async {
    _running = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    await _cleanupSocket();
    _sessionId = null;
    _peerDeviceId = null;
    _sharedSecret = null;
    _emit(const SyncStatus(state: SyncConnectionState.disconnected, message: '未连接'));
  }

  Future<void> pushMemo(Memo memo) async {
    final sessionId = _sessionId;
    final socket = _socket;
    if (sessionId == null || socket == null || _status.state != SyncConnectionState.online) {
      return;
    }
    await _writeFrame(
      socket,
      SyncPushMessage(sessionId: sessionId, memo: memo),
    );
  }

  Future<void> _runHandshake({
    required Socket socket,
    String? ticket,
    String? expectedPeerId,
  }) async {
    _emit(const SyncStatus(
      state: SyncConnectionState.handshaking,
      message: '握手中…',
    ));

    final identity = await _identity.ensureIdentity();

    final peerHello = await _readFrame(socket);
    if (peerHello is! HelloMessage) {
      throw FormatException('期望 hello，收到 ${peerHello.type}');
    }
    if (peerHello.protoVersion != protoVersion) {
      throw const FormatException('协议版本不匹配');
    }

    _peerDeviceId = peerHello.deviceId;
    await _writeFrame(socket, _identity.buildHello(identity));

    // Explicit QR / JSON pairing always re-runs pair_request so a stale local
    // peer record cannot skip pairing and then fail auth against the desktop.
    final forcePair = ticket != null && ticket.isNotEmpty;
    final existingPeer =
        forcePair ? null : await _store.findPeer(peerHello.deviceId);

    if (existingPeer != null) {
      _sharedSecret = existingPeer.sharedSecret;
    } else {
      if (ticket == null || ticket.isEmpty) {
        throw const FormatException('未配对，需要扫码配对');
      }
      // Drop stale trust so pair_ok secret becomes the source of truth.
      await _store.removePeer(peerHello.deviceId);

      final now = DateTime.now().millisecondsSinceEpoch;
      await _writeFrame(
        socket,
        PairRequestMessage(
          ticket: ticket,
          nonce: _identity.randomNonce(),
          ts: now,
        ),
      );

      final pairResp = await _readFrame(socket);
      switch (pairResp) {
        case PairOkMessage(:final peer, :final sharedSecret, :final pairedAt):
          _sharedSecret = sharedSecret;
          await _store.upsertPeer(
            TrustedPeer(
              deviceId: peer.deviceId,
              displayName: peer.displayName,
              publicKey: peer.publicKey,
              pairedAt: pairedAt,
              lastSeenAt: pairedAt,
              sharedSecret: sharedSecret,
            ),
          );
        case PairRejectMessage(:final reason):
          throw FormatException('配对被拒绝：$reason（请在电脑端刷新二维码后重试）');
        default:
          throw FormatException('期望 pair_ok，收到 ${pairResp.type}');
      }
    }

    if (_sharedSecret == null) {
      throw const FormatException('缺少共享密钥');
    }

    if (expectedPeerId != null && _peerDeviceId != expectedPeerId) {
      throw const FormatException('设备 ID 不匹配');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    await _writeFrame(
      socket,
      AuthMessage(
        deviceId: identity.deviceId,
        token: _identity.authToken(_sharedSecret!, identity.deviceId, ts),
        ts: ts,
      ),
    );

    final authResp = await _readFrame(socket);
    switch (authResp) {
      case AuthOkMessage(:final sessionId):
        _sessionId = sessionId;
      case AuthFailMessage(:final reason):
        throw FormatException(
          reason == 'unknown_device' || reason == 'bad_sig'
              ? '认证失败：$reason（请重新扫码配对）'
              : '认证失败：$reason',
        );
      case PairRejectMessage(:final reason):
        throw FormatException('配对被拒绝：$reason（请重新扫码）');
      default:
        throw FormatException('期望 auth_ok，收到 ${authResp.type}');
    }

    _emit(SyncStatus(
      state: SyncConnectionState.syncing,
      peerName: peerHello.displayName,
      message: '同步中…',
    ));

    final remoteSnap = await _readFrame(socket);
    if (remoteSnap is SyncSnapshotMessage) {
      var changed = false;
      for (final memo in remoteSnap.memos) {
        if (await _store.mergeMemo(memo)) {
          changed = true;
        }
      }
      if (changed) {
        _memoChangedController.add(null);
      }
      await _store.touchPeer(peerHello.deviceId, DateTime.now().millisecondsSinceEpoch);
    }

    final localMemos = await _store.listMemos(includeDeleted: true);
    await _writeFrame(
      socket,
      SyncSnapshotMessage(sessionId: _sessionId!, memos: localMemos),
    );

    _emit(SyncStatus(
      state: SyncConnectionState.online,
      peerName: peerHello.displayName,
      message: '已连接',
    ));

    _startPingLoop(socket);
  }

  Future<void> _runReadLoop(Socket socket) async {
    final peerName = _status.peerName;
    while (_running) {
      try {
        final msg = await _readFrame(socket);
        switch (msg) {
          case SyncPushMessage(:final memo):
            if (await _store.mergeMemo(memo)) {
              _memoChangedController.add(null);
            }
          case PingMessage(:final ts):
            await _writeFrame(socket, PongMessage(
              ts: DateTime.now().millisecondsSinceEpoch,
              echo: ts,
            ));
          case PongMessage():
            break;
          case SyncCaughtUpMessage(:final pendingOutbound):
            _emit(_status.copyWith(pendingOutbound: pendingOutbound));
          case ErrorMessage(:final message, :final fatal):
            if (fatal) {
              throw FormatException(message);
            }
          default:
            break;
        }
      } on SocketException {
        break;
      } on IOException {
        break;
      } on FormatException {
        break;
      }
    }

    _running = false;
    await _cleanupSocket();
    _sessionId = null;
    _emit(SyncStatus(
      state: SyncConnectionState.disconnected,
      peerName: peerName,
      message: '连接已断开',
    ));
  }

  void _startPingLoop(Socket socket) {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      if (!_running || _socket == null) return;
      try {
        await _writeFrame(
          socket,
          PingMessage(ts: DateTime.now().millisecondsSinceEpoch),
        );
      } catch (_) {
        await disconnect();
      }
    });
  }

  Future<WireMessage> _readFrame(Socket socket) async {
    final reader = _socketReaders.putIfAbsent(socket, () => _SocketReader(socket));
    final lenBytes = await reader.readExact(4);
    final len = ByteData.sublistView(lenBytes).getUint32(0, Endian.big);
    if (len > maxFrameSize) {
      throw const FormatException('帧过大');
    }
    final body = await reader.readExact(len);
    return WireMessage.decode(body);
  }

  Future<void> _writeFrame(Socket socket, WireMessage msg) async {
    final data = msg.encode();
    final header = ByteData(4)..setUint32(0, data.length, Endian.big);
    socket.add(header.buffer.asUint8List());
    socket.add(data);
    await socket.flush();
  }

  final Map<Socket, _SocketReader> _socketReaders = {};

  Future<void> _cleanupSocket() async {
    try {
      if (_socket != null) {
        await _socketReaders.remove(_socket!)?.close();
      }
      await _socket?.close();
    } catch (_) {}
    _socket = null;
  }

  void dispose() {
    _pingTimer?.cancel();
    _statusController.close();
    _memoChangedController.close();
  }
}

class _SocketReader {
  _SocketReader(this._socket) {
    _subscription = _socket.listen(
      (data) {
        _pending.addAll(data);
        _flushWaiters();
      },
      onError: (Object error, StackTrace stack) {
        for (final waiter in _waiters) {
          if (!waiter.completer.isCompleted) {
            waiter.completer.completeError(error, stack);
          }
        }
        _waiters.clear();
      },
      onDone: () {
        for (final waiter in _waiters) {
          if (!waiter.completer.isCompleted) {
            waiter.completer.completeError(const SocketException('连接已关闭'));
          }
        }
        _waiters.clear();
      },
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final List<int> _pending = [];
  late final StreamSubscription<Uint8List> _subscription;
  final List<_ReadWaiter> _waiters = [];

  Future<Uint8List> readExact(int length) async {
    while (_pending.length < length) {
      final waiter = _ReadWaiter(length);
      _waiters.add(waiter);
      await waiter.completer.future;
    }
    final bytes = Uint8List.fromList(_pending.sublist(0, length));
    _pending.removeRange(0, length);
    return bytes;
  }

  void _flushWaiters() {
    final done = <_ReadWaiter>[];
    for (final waiter in _waiters) {
      if (_pending.length >= waiter.length) {
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete();
        }
        done.add(waiter);
      }
    }
    for (final waiter in done) {
      _waiters.remove(waiter);
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
  }
}

class _ReadWaiter {
  _ReadWaiter(this.length);

  final int length;
  final Completer<void> completer = Completer<void>();
}
