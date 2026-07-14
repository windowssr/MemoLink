import 'package:flutter/material.dart';

import '../models/memo.dart';
import '../services/store.dart';
import '../services/sync_client.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.store,
    required this.syncClient,
  });

  final Store store;
  final SyncClient syncClient;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Memo> _memos = [];
  SyncStatus _syncStatus = const SyncStatus(state: SyncConnectionState.disconnected);
  bool _loading = true;
  /// Serializes visibility/done toggles so rapid taps can't use stale snapshots.
  Future<void> _toggleQueue = Future.value();

  @override
  void initState() {
    super.initState();
    _loadMemos();
    _syncStatus = widget.syncClient.currentStatus;
    widget.syncClient.statusStream.listen((status) {
      if (mounted) setState(() => _syncStatus = status);
    });
    widget.syncClient.memoChangedStream.listen((_) => _loadMemos());
  }

  Future<void> _loadMemos() async {
    final memos = await widget.store.listMemos();
    if (mounted) {
      setState(() {
        _memos = memos;
        _loading = false;
      });
    }
  }

  String _statusLabel() {
    switch (_syncStatus.state) {
      case SyncConnectionState.disconnected:
        return '未连接';
      case SyncConnectionState.connecting:
        return '连接中…';
      case SyncConnectionState.handshaking:
        return '握手中…';
      case SyncConnectionState.syncing:
        return '同步中…';
      case SyncConnectionState.online:
        final peer = _syncStatus.peerName;
        return peer != null ? '已连接 · $peer' : '已连接';
      case SyncConnectionState.error:
        return _syncStatus.message ?? '连接错误';
    }
  }

  Color _statusColor() {
    switch (_syncStatus.state) {
      case SyncConnectionState.online:
        return const Color(0xFF6B8F71);
      case SyncConnectionState.error:
        return const Color(0xFFB85C5C);
      case SyncConnectionState.disconnected:
        return const Color(0xFF9A8F82);
      default:
        return const Color(0xFFC4A574);
    }
  }

  Color _memoColor(String color) {
    switch (color) {
      case 'pink':
        return const Color(0xFFF8E0E8);
      case 'blue':
        return const Color(0xFFDCE8F5);
      case 'green':
        return const Color(0xFFDCE8D8);
      case 'gray':
        return const Color(0xFFE8E4DE);
      default:
        return const Color(0xFFFFF3C4);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MemoLink'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () async {
              await Navigator.of(context).pushNamed('/settings');
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _SyncStatusBar(
            label: _statusLabel(),
            color: _statusColor(),
            pending: _syncStatus.pendingOutbound,
            onPair: () async {
              final ok = await Navigator.of(context).pushNamed('/pair');
              if (ok == true && mounted) {
                await _loadMemos();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('配对成功')),
                );
              }
            },
            onReconnect: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('正在重连…')),
              );
              await widget.syncClient.reconnectLastPeer();
            },
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _memos.isEmpty
                    ? const Center(
                        child: Text(
                          '还没有便签\n点击右下角新建',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF9A8F82)),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadMemos,
                        child: ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: _memos.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final memo = _memos[index];
                            return _MemoCard(
                              key: ValueKey(memo.id),
                              memo: memo,
                              background: _memoColor(memo.color),
                              onTap: () async {
                                await Navigator.pushNamed(
                                  context,
                                  '/edit',
                                  arguments: memo,
                                );
                                await _loadMemos();
                              },
                              onToggleDone: () => _toggleDone(memo.id),
                              onToggleDesktop: () =>
                                  _toggleDesktopVisible(memo.id),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.pushNamed(context, '/edit');
          await _loadMemos();
        },
        tooltip: '新建便签',
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _toggleDone(String id) {
    _toggleQueue = _toggleQueue
        .catchError((_) {})
        .then((_) => _toggleDoneImpl(id));
    return _toggleQueue;
  }

  Future<void> _toggleDoneImpl(String id) async {
    final latest = await widget.store.getMemo(id);
    if (latest == null || latest.deleted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = latest.copyWith(
      done: !latest.done,
      updatedAt: now,
      revision: latest.revision + 1,
    );
    _patchLocalMemo(updated);
    await widget.store.upsertMemo(updated);
    await widget.syncClient.pushMemo(updated);
  }

  /// Matches desktop: visible when pinned && !archived
  Future<void> _toggleDesktopVisible(String id) {
    _toggleQueue = _toggleQueue
        .catchError((_) {})
        .then((_) => _toggleDesktopVisibleImpl(id));
    return _toggleQueue;
  }

  Future<void> _toggleDesktopVisibleImpl(String id) async {
    final latest = await widget.store.getMemo(id);
    if (latest == null || latest.deleted) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final showing = latest.pinned && !latest.archived;
    final updated = latest.copyWith(
      pinned: !showing,
      archived: !showing ? false : latest.archived,
      updatedAt: now,
      revision: latest.revision + 1,
    );
    _patchLocalMemo(updated);
    await widget.store.upsertMemo(updated);
    await widget.syncClient.pushMemo(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(showing ? '已从电脑桌面隐藏' : '已显示到电脑桌面'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _patchLocalMemo(Memo updated) {
    if (!mounted) return;
    setState(() {
      _memos = [
        for (final m in _memos)
          if (m.id == updated.id) updated else m,
      ];
    });
  }
}

class _SyncStatusBar extends StatelessWidget {
  const _SyncStatusBar({
    required this.label,
    required this.color,
    required this.pending,
    required this.onPair,
    required this.onReconnect,
  });

  final String label;
  final Color color;
  final int pending;
  final VoidCallback onPair;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFE8DFD0))),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3D3429),
                  ),
                ),
                if (pending > 0)
                  Text(
                    '待发送 $pending 条',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF9A8F82),
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: onReconnect,
            child: const Text('重连'),
          ),
          TextButton(
            onPressed: onPair,
            child: const Text('配对'),
          ),
        ],
      ),
    );
  }
}

class _MemoCard extends StatelessWidget {
  const _MemoCard({
    super.key,
    required this.memo,
    required this.background,
    required this.onTap,
    required this.onToggleDone,
    required this.onToggleDesktop,
  });

  final Memo memo;
  final Color background;
  final VoidCallback onTap;
  final VoidCallback onToggleDone;
  final VoidCallback onToggleDesktop;

  bool get _onDesktop => memo.pinned && !memo.archived;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE8DFD0)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                icon: Icon(
                  memo.done ? Icons.check_circle : Icons.circle_outlined,
                  color: memo.done
                      ? const Color(0xFF6B8F71)
                      : const Color(0xFF9A8F82),
                ),
                onPressed: onToggleDone,
                visualDensity: VisualDensity.compact,
                tooltip: '完成',
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _onDesktop
                                ? const Color(0xFF2B2A28)
                                : const Color(0xFFE8DFD0),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            _onDesktop ? '桌面显示中' : '桌面已隐藏',
                            style: TextStyle(
                              fontSize: 11,
                              color: _onDesktop
                                  ? const Color(0xFFF5F0E8)
                                  : const Color(0xFF6B645A),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      memo.body.isEmpty ? '（空便签）' : memo.body,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        color: const Color(0xFF3D3429),
                        decoration:
                            memo.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  _onDesktop
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: const Color(0xFF5C564C),
                ),
                onPressed: onToggleDesktop,
                tooltip: _onDesktop ? '从电脑桌面隐藏' : '显示到电脑桌面',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
