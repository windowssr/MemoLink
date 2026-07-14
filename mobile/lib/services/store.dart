import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/device.dart';
import '../models/memo.dart';

class Store {
  Store._(this._db);

  final Database _db;

  static Store? _instance;

  static Future<Store> open() async {
    if (_instance != null) return _instance!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'memolink.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (database, version) async {
        await database.execute('''
          CREATE TABLE identity (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            device_id TEXT NOT NULL,
            display_name TEXT NOT NULL,
            public_key TEXT NOT NULL,
            secret TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE peers (
            device_id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            public_key TEXT NOT NULL,
            paired_at INTEGER NOT NULL,
            last_seen_at INTEGER,
            shared_secret TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE memos (
            id TEXT PRIMARY KEY,
            body TEXT NOT NULL,
            color TEXT NOT NULL,
            pinned INTEGER NOT NULL,
            done INTEGER NOT NULL,
            archived INTEGER NOT NULL,
            deleted INTEGER NOT NULL,
            desktop_x REAL,
            desktop_y REAL,
            desktop_w REAL,
            desktop_h REAL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            revision INTEGER NOT NULL,
            origin_device_id TEXT NOT NULL
          )
        ''');
        await database.execute('''
          CREATE TABLE meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
    _instance = Store._(db);
    return _instance!;
  }

  Future<DeviceIdentity?> getIdentity() async {
    final rows = await _db.query('identity', where: 'id = ?', whereArgs: [1]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return DeviceIdentity(
      deviceId: row['device_id'] as String,
      displayName: row['display_name'] as String,
      publicKey: row['public_key'] as String,
      secret: row['secret'] as String,
    );
  }

  Future<void> saveIdentity(DeviceIdentity identity) async {
    await _db.insert(
      'identity',
      {
        'id': 1,
        'device_id': identity.deviceId,
        'display_name': identity.displayName,
        'public_key': identity.publicKey,
        'secret': identity.secret,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateDisplayName(String displayName) async {
    await _db.update(
      'identity',
      {'display_name': displayName},
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  Future<List<TrustedPeer>> listPeers() async {
    final rows = await _db.query('peers');
    return rows
        .map(
          (row) => TrustedPeer(
            deviceId: row['device_id'] as String,
            displayName: row['display_name'] as String,
            publicKey: row['public_key'] as String,
            pairedAt: row['paired_at'] as int,
            lastSeenAt: row['last_seen_at'] as int?,
            sharedSecret: row['shared_secret'] as String,
          ),
        )
        .toList();
  }

  Future<TrustedPeer?> findPeer(String deviceId) async {
    final rows = await _db.query(
      'peers',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return TrustedPeer(
      deviceId: row['device_id'] as String,
      displayName: row['display_name'] as String,
      publicKey: row['public_key'] as String,
      pairedAt: row['paired_at'] as int,
      lastSeenAt: row['last_seen_at'] as int?,
      sharedSecret: row['shared_secret'] as String,
    );
  }

  Future<void> upsertPeer(TrustedPeer peer) async {
    await _db.insert(
      'peers',
      {
        'device_id': peer.deviceId,
        'display_name': peer.displayName,
        'public_key': peer.publicKey,
        'paired_at': peer.pairedAt,
        'last_seen_at': peer.lastSeenAt,
        'shared_secret': peer.sharedSecret,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> touchPeer(String deviceId, int ts) async {
    await _db.update(
      'peers',
      {'last_seen_at': ts},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  Future<void> removePeer(String deviceId) async {
    await _db.delete('peers', where: 'device_id = ?', whereArgs: [deviceId]);
  }

  Memo _memoFromRow(Map<String, Object?> row) {
    return Memo(
      id: row['id'] as String,
      body: row['body'] as String,
      color: row['color'] as String,
      pinned: (row['pinned'] as int) != 0,
      done: (row['done'] as int) != 0,
      archived: (row['archived'] as int) != 0,
      deleted: (row['deleted'] as int) != 0,
      desktopX: row['desktop_x'] as double?,
      desktopY: row['desktop_y'] as double?,
      desktopW: row['desktop_w'] as double?,
      desktopH: row['desktop_h'] as double?,
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
      revision: row['revision'] as int,
      originDeviceId: row['origin_device_id'] as String,
    );
  }

  Future<List<Memo>> listMemos({bool includeDeleted = false}) async {
    final rows = await _db.query(
      'memos',
      where: includeDeleted ? null : 'deleted = 0',
      // Keep list order stable when toggling desktop visibility (pinned).
      orderBy: 'updated_at DESC',
    );
    return rows.map(_memoFromRow).toList();
  }

  Future<Memo?> getMemo(String id) async {
    final rows = await _db.query('memos', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _memoFromRow(rows.first);
  }

  Future<void> upsertMemo(Memo memo) async {
    await _db.insert(
      'memos',
      {
        'id': memo.id,
        'body': memo.body,
        'color': memo.color,
        'pinned': memo.pinned ? 1 : 0,
        'done': memo.done ? 1 : 0,
        'archived': memo.archived ? 1 : 0,
        'deleted': memo.deleted ? 1 : 0,
        'desktop_x': memo.desktopX,
        'desktop_y': memo.desktopY,
        'desktop_w': memo.desktopW,
        'desktop_h': memo.desktopH,
        'created_at': memo.createdAt,
        'updated_at': memo.updatedAt,
        'revision': memo.revision,
        'origin_device_id': memo.originDeviceId,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> mergeMemo(Memo incoming) async {
    final existing = await getMemo(incoming.id);
    if (existing == null) {
      await upsertMemo(incoming);
      return true;
    }
    if (incoming.winsOver(existing)) {
      await upsertMemo(incoming);
      return true;
    }
    return false;
  }

  Future<void> setMeta(String key, String value) async {
    await _db.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getMeta(String key) async {
    final rows = await _db.query('meta', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }
}
