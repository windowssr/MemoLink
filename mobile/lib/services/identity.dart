import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../models/protocol.dart';
import 'store.dart';

const _uuid = Uuid();

class IdentityService {
  IdentityService(this._store);

  final Store _store;

  Future<DeviceIdentity> ensureIdentity() async {
    final existing = await _store.getIdentity();
    if (existing != null) return existing;

    final secretBytes = _randomBytes(32);
    final secret = _base64UrlNoPad(secretBytes);
    final publicKey = _base64UrlNoPad(sha256.convert(utf8.encode(secret)).bytes);

    final identity = DeviceIdentity(
      deviceId: _uuid.v4(),
      displayName: '我的手机',
      publicKey: publicKey,
      secret: secret,
    );
    await _store.saveIdentity(identity);
    return identity;
  }

  Future<DeviceIdentity> getIdentity() => ensureIdentity();

  Future<void> setDisplayName(String name) async {
    await _store.updateDisplayName(name);
  }

  String authToken(String sharedSecret, String deviceId, int ts) {
    final input = utf8.encode('$sharedSecret|$deviceId|$ts');
    return _base64UrlNoPad(sha256.convert(input).bytes);
  }

  String fingerprint(String publicKey) {
    final digest = sha256.convert(utf8.encode(publicKey));
    return digest.bytes
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String randomNonce() => _base64UrlNoPad(_randomBytes(32));

  HelloMessage buildHello(DeviceIdentity identity) {
    return HelloMessage(
      protoVersion: protoVersion,
      deviceId: identity.deviceId,
      displayName: identity.displayName,
      publicKey: identity.publicKey,
      caps: const ['sync.v1', 'lan.mdns'],
      role: 'mobile',
    );
  }
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

String _base64UrlNoPad(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}
