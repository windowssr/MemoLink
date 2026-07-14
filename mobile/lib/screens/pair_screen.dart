import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/device.dart';
import '../services/store.dart';
import '../services/sync_client.dart';

class PairScreen extends StatefulWidget {
  const PairScreen({
    super.key,
    required this.store,
    required this.syncClient,
  });

  final Store store;
  final SyncClient syncClient;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  MobileScannerController? _scannerController;
  bool _processing = false;
  bool _cameraReady = false;
  String? _cameraError;
  String? _status;
  String? _error;
  final _jsonController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _prepareCamera();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _scannerController?.dispose();
    _jsonController.dispose();
    super.dispose();
  }

  Future<void> _prepareCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _cameraError = status.isPermanentlyDenied
            ? '相机权限被永久拒绝，请到系统设置开启，或改用「粘贴 JSON」'
            : '未授予相机权限，请授权后重试，或改用「粘贴 JSON」';
        _cameraReady = false;
      });
      return;
    }
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
    if (mounted) {
      setState(() {
        _cameraReady = true;
        _cameraError = null;
      });
    }
  }

  Future<void> _connectWithPayload(PairingPayload payload) async {
    setState(() {
      _processing = true;
      _error = null;
      _status = '正在连接 ${payload.displayName}…';
    });

    try {
      if (payload.product != 'memolink') {
        throw const FormatException('不是 MemoLink 配对数据');
      }

      await _scannerController?.stop();
      await widget.store.setMeta('last_host', payload.lan.host);
      await widget.store.setMeta('last_port', payload.lan.port.toString());

      await widget.syncClient.connectToPeer(
        host: payload.lan.host,
        port: payload.lan.port,
        pairingPayload: payload,
      );

      if (!mounted) return;
      final status = widget.syncClient.currentStatus;
      if (status.state == SyncConnectionState.online) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _error = status.message ?? '配对失败';
        _processing = false;
        _status = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _processing = false;
        _status = null;
      });
    }
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final payload = PairingPayload.fromJson(json);
      await _connectWithPayload(payload);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '二维码无效：$e';
        _processing = false;
      });
    }
  }

  Future<void> _connectFromJson() async {
    if (_processing) return;
    final raw = _jsonController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请粘贴电脑端「复制配对 JSON」的内容');
      return;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final payload = PairingPayload.fromJson(json);
      await _connectWithPayload(payload);
    } catch (e) {
      setState(() => _error = 'JSON 无效：$e');
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      setState(() => _error = '剪贴板为空');
      return;
    }
    _jsonController.text = text;
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('配对电脑'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '扫码'),
            Tab(text: '粘贴 JSON'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_status != null || _error != null || _processing)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                children: [
                  if (_status != null)
                    Text(_status!, style: const TextStyle(color: Color(0xFFC4A574))),
                  if (_error != null)
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFB85C5C)),
                    ),
                  if (_processing)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildScannerTab(),
                _buildPasteTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerTab() {
    if (_cameraError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48, color: Color(0xFF9A8F82)),
            const SizedBox(height: 16),
            Text(_cameraError!, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                await openAppSettings();
              },
              child: const Text('打开系统设置'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                _tabs.animateTo(1);
              },
              child: const Text('改用粘贴 JSON'),
            ),
            TextButton(
              onPressed: _prepareCamera,
              child: const Text('重新申请权限'),
            ),
          ],
        ),
      );
    }

    if (!_cameraReady || _scannerController == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: MobileScanner(
                controller: _scannerController!,
                onDetect: _handleBarcode,
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Text(
            '将镜头对准电脑上的二维码。若一直黑屏，请切到「粘贴 JSON」。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF9A8F82)),
          ),
        ),
      ],
    );
  }

  Widget _buildPasteTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '请确保手机与电脑在同一 WiFi（关闭 5G/4G 流量），否则会连接超时。',
            style: TextStyle(color: Color(0xFF6B645A)),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _jsonController,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                hintText: '{"v":1,"product":"memolink",...}',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _processing ? null : _pasteFromClipboard,
                  child: const Text('从剪贴板粘贴'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _processing ? null : _connectFromJson,
                  child: const Text('连接'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
