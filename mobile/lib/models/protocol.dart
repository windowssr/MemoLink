import 'dart:convert';
import 'dart:typed_data';

import 'memo.dart';
import 'device.dart';

const int protoVersion = 1;
const int defaultPort = 47820;
const int maxFrameSize = 1048576;

sealed class WireMessage {
  const WireMessage();

  String get type;

  Map<String, dynamic> toJson();

  static WireMessage fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'hello':
        return HelloMessage.fromJson(json);
      case 'pair_request':
        return PairRequestMessage.fromJson(json);
      case 'pair_ok':
        return PairOkMessage.fromJson(json);
      case 'pair_reject':
        return PairRejectMessage.fromJson(json);
      case 'auth':
        return AuthMessage.fromJson(json);
      case 'auth_ok':
        return AuthOkMessage.fromJson(json);
      case 'auth_fail':
        return AuthFailMessage.fromJson(json);
      case 'sync_snapshot':
        return SyncSnapshotMessage.fromJson(json);
      case 'sync_push':
        return SyncPushMessage.fromJson(json);
      case 'sync_caught_up':
        return SyncCaughtUpMessage.fromJson(json);
      case 'ping':
        return PingMessage.fromJson(json);
      case 'pong':
        return PongMessage.fromJson(json);
      case 'error':
        return ErrorMessage.fromJson(json);
      default:
        throw FormatException('unknown wire message type: $type');
    }
  }

  static WireMessage decode(Uint8List bytes) {
    return fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
  }

  Uint8List encode() {
    return Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
  }
}

class HelloMessage extends WireMessage {
  HelloMessage({
    required this.protoVersion,
    required this.deviceId,
    required this.displayName,
    required this.publicKey,
    required this.caps,
    required this.role,
  });

  final int protoVersion;
  final String deviceId;
  final String displayName;
  final String publicKey;
  final List<String> caps;
  final String role;

  @override
  String get type => 'hello';

  factory HelloMessage.fromJson(Map<String, dynamic> json) {
    return HelloMessage(
      protoVersion: json['protoVersion'] as int,
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      publicKey: json['publicKey'] as String,
      caps: (json['caps'] as List<dynamic>? ?? [])
          .map((e) => e as String)
          .toList(),
      role: json['role'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'protoVersion': protoVersion,
        'deviceId': deviceId,
        'displayName': displayName,
        'publicKey': publicKey,
        'caps': caps,
        'role': role,
      };
}

class PairRequestMessage extends WireMessage {
  PairRequestMessage({
    required this.ticket,
    required this.nonce,
    required this.ts,
  });

  final String ticket;
  final String nonce;
  final int ts;

  @override
  String get type => 'pair_request';

  factory PairRequestMessage.fromJson(Map<String, dynamic> json) {
    return PairRequestMessage(
      ticket: json['ticket'] as String,
      nonce: json['nonce'] as String,
      ts: json['ts'] as int,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'ticket': ticket,
        'nonce': nonce,
        'ts': ts,
      };
}

class PairOkMessage extends WireMessage {
  PairOkMessage({
    required this.pairedAt,
    required this.peer,
    required this.sharedSecret,
  });

  final int pairedAt;
  final PeerInfo peer;
  final String sharedSecret;

  @override
  String get type => 'pair_ok';

  factory PairOkMessage.fromJson(Map<String, dynamic> json) {
    return PairOkMessage(
      pairedAt: json['pairedAt'] as int,
      peer: PeerInfo.fromJson(json['peer'] as Map<String, dynamic>),
      sharedSecret: json['sharedSecret'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'pairedAt': pairedAt,
        'peer': {
          'deviceId': peer.deviceId,
          'displayName': peer.displayName,
          'publicKey': peer.publicKey,
        },
        'sharedSecret': sharedSecret,
      };
}

class PairRejectMessage extends WireMessage {
  PairRejectMessage({required this.reason});

  final String reason;

  @override
  String get type => 'pair_reject';

  factory PairRejectMessage.fromJson(Map<String, dynamic> json) {
    return PairRejectMessage(reason: json['reason'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'reason': reason,
      };
}

class AuthMessage extends WireMessage {
  AuthMessage({
    required this.deviceId,
    required this.token,
    required this.ts,
  });

  final String deviceId;
  final String token;
  final int ts;

  @override
  String get type => 'auth';

  factory AuthMessage.fromJson(Map<String, dynamic> json) {
    return AuthMessage(
      deviceId: json['deviceId'] as String,
      token: json['token'] as String,
      ts: json['ts'] as int,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'deviceId': deviceId,
        'token': token,
        'ts': ts,
      };
}

class AuthOkMessage extends WireMessage {
  AuthOkMessage({
    required this.sessionId,
    required this.serverTime,
  });

  final String sessionId;
  final int serverTime;

  @override
  String get type => 'auth_ok';

  factory AuthOkMessage.fromJson(Map<String, dynamic> json) {
    return AuthOkMessage(
      sessionId: json['sessionId'] as String,
      serverTime: json['serverTime'] as int,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'sessionId': sessionId,
        'serverTime': serverTime,
      };
}

class AuthFailMessage extends WireMessage {
  AuthFailMessage({required this.reason});

  final String reason;

  @override
  String get type => 'auth_fail';

  factory AuthFailMessage.fromJson(Map<String, dynamic> json) {
    return AuthFailMessage(reason: json['reason'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'reason': reason,
      };
}

class SyncSnapshotMessage extends WireMessage {
  SyncSnapshotMessage({
    required this.sessionId,
    required this.memos,
  });

  final String sessionId;
  final List<Memo> memos;

  @override
  String get type => 'sync_snapshot';

  factory SyncSnapshotMessage.fromJson(Map<String, dynamic> json) {
    return SyncSnapshotMessage(
      sessionId: json['sessionId'] as String,
      memos: (json['memos'] as List<dynamic>? ?? [])
          .map((e) => Memo.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'sessionId': sessionId,
        'memos': memos.map((m) => m.toJson()).toList(),
      };
}

class SyncPushMessage extends WireMessage {
  SyncPushMessage({
    required this.sessionId,
    required this.memo,
  });

  final String sessionId;
  final Memo memo;

  @override
  String get type => 'sync_push';

  factory SyncPushMessage.fromJson(Map<String, dynamic> json) {
    return SyncPushMessage(
      sessionId: json['sessionId'] as String,
      memo: Memo.fromJson(json['memo'] as Map<String, dynamic>),
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'sessionId': sessionId,
        'memo': memo.toJson(),
      };
}

class SyncCaughtUpMessage extends WireMessage {
  SyncCaughtUpMessage({
    required this.sessionId,
    required this.pendingOutbound,
  });

  final String sessionId;
  final int pendingOutbound;

  @override
  String get type => 'sync_caught_up';

  factory SyncCaughtUpMessage.fromJson(Map<String, dynamic> json) {
    return SyncCaughtUpMessage(
      sessionId: json['sessionId'] as String,
      pendingOutbound: json['pendingOutbound'] as int? ?? 0,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'sessionId': sessionId,
        'pendingOutbound': pendingOutbound,
      };
}

class PingMessage extends WireMessage {
  PingMessage({required this.ts});

  final int ts;

  @override
  String get type => 'ping';

  factory PingMessage.fromJson(Map<String, dynamic> json) {
    return PingMessage(ts: json['ts'] as int);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'ts': ts,
      };
}

class PongMessage extends WireMessage {
  PongMessage({required this.ts, required this.echo});

  final int ts;
  final int echo;

  @override
  String get type => 'pong';

  factory PongMessage.fromJson(Map<String, dynamic> json) {
    return PongMessage(
      ts: json['ts'] as int,
      echo: json['echo'] as int,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'ts': ts,
        'echo': echo,
      };
}

class ErrorMessage extends WireMessage {
  ErrorMessage({
    required this.code,
    required this.message,
    required this.fatal,
  });

  final String code;
  final String message;
  final bool fatal;

  @override
  String get type => 'error';

  factory ErrorMessage.fromJson(Map<String, dynamic> json) {
    return ErrorMessage(
      code: json['code'] as String,
      message: json['message'] as String? ?? '',
      fatal: json['fatal'] as bool? ?? false,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'code': code,
        'message': message,
        'fatal': fatal,
      };
}
