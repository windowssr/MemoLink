class Memo {
  Memo({
    required this.id,
    required this.body,
    this.color = 'yellow',
    this.pinned = false,
    this.done = false,
    this.archived = false,
    this.deleted = false,
    this.desktopX,
    this.desktopY,
    this.desktopW,
    this.desktopH,
    required this.createdAt,
    required this.updatedAt,
    this.revision = 0,
    required this.originDeviceId,
  });

  final String id;
  final String body;
  final String color;
  final bool pinned;
  final bool done;
  final bool archived;
  final bool deleted;
  final double? desktopX;
  final double? desktopY;
  final double? desktopW;
  final double? desktopH;
  final int createdAt;
  final int updatedAt;
  final int revision;
  final String originDeviceId;

  bool winsOver(Memo other) {
    if (updatedAt != other.updatedAt) {
      return updatedAt > other.updatedAt;
    }
    if (revision != other.revision) {
      return revision > other.revision;
    }
    return originDeviceId.compareTo(other.originDeviceId) > 0;
  }

  Memo copyWith({
    String? id,
    String? body,
    String? color,
    bool? pinned,
    bool? done,
    bool? archived,
    bool? deleted,
    double? desktopX,
    double? desktopY,
    double? desktopW,
    double? desktopH,
    int? createdAt,
    int? updatedAt,
    int? revision,
    String? originDeviceId,
  }) {
    return Memo(
      id: id ?? this.id,
      body: body ?? this.body,
      color: color ?? this.color,
      pinned: pinned ?? this.pinned,
      done: done ?? this.done,
      archived: archived ?? this.archived,
      deleted: deleted ?? this.deleted,
      desktopX: desktopX ?? this.desktopX,
      desktopY: desktopY ?? this.desktopY,
      desktopW: desktopW ?? this.desktopW,
      desktopH: desktopH ?? this.desktopH,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      revision: revision ?? this.revision,
      originDeviceId: originDeviceId ?? this.originDeviceId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'body': body,
        'color': color,
        'pinned': pinned,
        'done': done,
        'archived': archived,
        'deleted': deleted,
        if (desktopX != null) 'desktopX': desktopX,
        if (desktopY != null) 'desktopY': desktopY,
        if (desktopW != null) 'desktopW': desktopW,
        if (desktopH != null) 'desktopH': desktopH,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'revision': revision,
        'originDeviceId': originDeviceId,
      };

  factory Memo.fromJson(Map<String, dynamic> json) {
    return Memo(
      id: json['id'] as String,
      body: json['body'] as String? ?? '',
      color: json['color'] as String? ?? 'yellow',
      pinned: json['pinned'] as bool? ?? false,
      done: json['done'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      deleted: json['deleted'] as bool? ?? false,
      desktopX: (json['desktopX'] as num?)?.toDouble(),
      desktopY: (json['desktopY'] as num?)?.toDouble(),
      desktopW: (json['desktopW'] as num?)?.toDouble(),
      desktopH: (json['desktopH'] as num?)?.toDouble(),
      createdAt: json['createdAt'] as int,
      updatedAt: json['updatedAt'] as int,
      revision: json['revision'] as int? ?? 0,
      originDeviceId: json['originDeviceId'] as String,
    );
  }
}
