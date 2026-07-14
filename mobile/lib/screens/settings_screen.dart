import 'package:flutter/material.dart';

import '../services/identity.dart';
import '../services/store.dart';
import '../services/sync_client.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.store,
    required this.identity,
    required this.syncClient,
  });

  final Store store;
  final IdentityService identity;
  final SyncClient syncClient;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _nameController = TextEditingController();
  String? _deviceId;
  List<String> _peers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final identity = await widget.identity.getIdentity();
    final peers = await widget.store.listPeers();
    if (!mounted) return;
    setState(() {
      _deviceId = identity.deviceId;
      _nameController.text = identity.displayName;
      _peers = peers.map((p) => '${p.displayName} (${p.deviceId.substring(0, 8)}…)').toList();
      _loading = false;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    await widget.identity.setDisplayName(name);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称已保存')),
      );
    }
  }

  Future<void> _forgetPeers() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除配对'),
        content: const Text('将删除所有已配对设备，需要重新扫码配对。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final peers = await widget.store.listPeers();
    for (final peer in peers) {
      await widget.store.removePeer(peer.deviceId);
    }
    await widget.syncClient.disconnect();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清除配对信息')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '本机信息',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF9A8F82),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '设备 ID',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          _deviceId ?? '',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _nameController,
                          decoration: const InputDecoration(
                            labelText: '显示名称',
                          ),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _saveName,
                            child: const Text('保存名称'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  '已配对设备',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF9A8F82),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: _peers.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无配对设备'),
                        )
                      : Column(
                          children: _peers
                              .map(
                                (p) => ListTile(
                                  leading: const Icon(Icons.computer),
                                  title: Text(p),
                                ),
                              )
                              .toList(),
                        ),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: _forgetPeers,
                  icon: const Icon(Icons.link_off),
                  label: const Text('清除所有配对'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFB85C5C),
                    side: const BorderSide(color: Color(0xFFB85C5C)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'MemoLink 手机端通过局域网与桌面端同步便签。',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF9A8F82),
                  ),
                ),
              ],
            ),
    );
  }
}
