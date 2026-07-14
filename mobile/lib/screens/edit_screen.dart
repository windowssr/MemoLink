import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/memo.dart';
import '../services/identity.dart';
import '../services/store.dart';
import '../services/sync_client.dart';

const _uuid = Uuid();

class EditScreen extends StatefulWidget {
  const EditScreen({
    super.key,
    required this.store,
    required this.identity,
    required this.syncClient,
    this.memo,
  });

  final Store store;
  final IdentityService identity;
  final SyncClient syncClient;
  final Memo? memo;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  late final TextEditingController _bodyController;
  late String _color;
  late bool _pinned;
  bool _saving = false;

  static const _colors = [
    ('yellow', '黄色', Color(0xFFFFF3C4)),
    ('pink', '粉色', Color(0xFFF8E0E8)),
    ('blue', '蓝色', Color(0xFFDCE8F5)),
    ('green', '绿色', Color(0xFFDCE8D8)),
    ('gray', '灰色', Color(0xFFE8E4DE)),
  ];

  bool get _isNew => widget.memo == null;

  @override
  void initState() {
    super.initState();
    _bodyController = TextEditingController(text: widget.memo?.body ?? '');
    _color = widget.memo?.color ?? 'yellow';
    // Desktop visibility = pinned && !archived
    _pinned = widget.memo == null
        ? true
        : (widget.memo!.pinned && !widget.memo!.archived);
  }

  @override
  void dispose() {
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      final identity = await widget.identity.getIdentity();
      final dt = DateTime.now();
      final now = dt.millisecondsSinceEpoch;
      final raw = _bodyController.text.trim();
      final date =
          '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

      final Memo memo;
      if (_isNew) {
        final body = raw.isEmpty
            ? date
            : (raw.startsWith(date) ? raw : '$date\n$raw');
        memo = Memo(
          id: _uuid.v4(),
          body: body,
          color: _color,
          pinned: true,
          createdAt: now,
          updatedAt: now,
          revision: 1,
          originDeviceId: identity.deviceId,
        );
      } else {
        final existing = widget.memo!;
        memo = existing.copyWith(
          body: raw,
          color: _color,
          pinned: _pinned,
          archived: _pinned ? false : existing.archived,
          updatedAt: now,
          revision: existing.revision + 1,
          originDeviceId: identity.deviceId,
        );
      }

      await widget.store.upsertMemo(memo);
      await widget.syncClient.pushMemo(memo);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除便签'),
        content: const Text('确定要删除这条便签吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || widget.memo == null) return;

    final existing = widget.memo!;
    final now = DateTime.now().millisecondsSinceEpoch;
    final deleted = existing.copyWith(
      deleted: true,
      updatedAt: now,
      revision: existing.revision + 1,
    );
    await widget.store.upsertMemo(deleted);
    await widget.syncClient.pushMemo(deleted);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建便签' : '编辑便签'),
        actions: [
          if (!_isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '删除',
              onPressed: _delete,
            ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _bodyController,
            maxLines: 8,
            maxLength: 4096,
            decoration: const InputDecoration(
              hintText: '写点什么…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            '颜色',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _colors.map((entry) {
              final selected = _color == entry.$1;
              return ChoiceChip(
                label: Text(entry.$2),
                selected: selected,
                avatar: CircleAvatar(backgroundColor: entry.$3, radius: 10),
                onSelected: (_) => setState(() => _color = entry.$1),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          SwitchListTile(
            title: const Text('在电脑桌面显示'),
            subtitle: const Text('关闭后电脑上不再挂出这条便签'),
            value: _pinned,
            onChanged: (v) => setState(() => _pinned = v),
          ),
        ],
      ),
    );
  }
}
