class DeviceIdentity {
  DeviceIdentity({
    required this.deviceId,
    required this.displayName,
    required this.publicKey,
    required this.secret,
  });

  final String deviceId;
  final String displayName;
  final String publicKey;
  final String secret;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'publicKey': publicKey,
        'secret': secret,
      };

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) {
    return DeviceIdentity(
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      publicKey: json['publicKey'] as String,
      secret: json['secret'] as String,
    );
  }
}

class TrustedPeer {
  TrustedPeer({
    required this.deviceId,
    required this.displayName,
    required this.publicKey,
    required this.pairedAt,
    this.lastSeenAt,
    required this.sharedSecret,
  });

  final String deviceId;
  final String displayName;
  final String publicKey;
  final int pairedAt;
  final int? lastSeenAt;
  final String sharedSecret;

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'publicKey': publicKey,
        'pairedAt': pairedAt,
        if (lastSeenAt != null) 'lastSeenAt': lastSeenAt,
        'sharedSecret': sharedSecret,
      };

  factory TrustedPeer.fromJson(Map<String, dynamic> json) {
    return TrustedPeer(
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      publicKey: json['publicKey'] as String,
      pairedAt: json['pairedAt'] as int,
      lastSeenAt: json['lastSeenAt'] as int?,
      sharedSecret: json['sharedSecret'] as String,
    );
  }
}

class PeerInfo {
  PeerInfo({
    required this.deviceId,
    required this.displayName,
    required this.publicKey,
  });

  final String deviceId;
  final String displayName;
  final String publicKey;

  factory PeerInfo.fromJson(Map<String, dynamic> json) {
    return PeerInfo(
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      publicKey: json['publicKey'] as String,
    );
  }
}

class LanInfo {
  LanInfo({
    required this.host,
    required this.port,
    required this.service,
  });

  final String host;
  final int port;
  final String service;

  factory LanInfo.fromJson(Map<String, dynamic> json) {
    return LanInfo(
      host: json['host'] as String,
      port: json['port'] as int,
      service: json['service'] as String? ?? '_memolink._tcp.local',
    );
  }
}

class PairingPayload {
  PairingPayload({
    required this.v,
    required this.product,
    required this.deviceId,
    required this.displayName,
    required this.publicKey,
    required this.fingerprint,
    required this.ticket,
    required this.lan,
  });

  final int v;
  final String product;
  final String deviceId;
  final String displayName;
  final String publicKey;
  final String fingerprint;
  final String ticket;
  final LanInfo lan;

  factory PairingPayload.fromJson(Map<String, dynamic> json) {
    return PairingPayload(
      v: json['v'] as int? ?? 1,
      product: json['product'] as String? ?? 'memolink',
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      publicKey: json['publicKey'] as String,
      fingerprint: json['fingerprint'] as String? ?? '',
      ticket: json['ticket'] as String,
      lan: LanInfo.fromJson(json['lan'] as Map<String, dynamic>),
    );
  }
}
