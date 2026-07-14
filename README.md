# MemoLink

轻量级 P2P 备忘录：手机随手记，Windows 桌面悬浮便签一眼见。数据只在设备之间流动；当前 MVP 仅同一 WiFi 局域网（TCP `47820`），无需公网 IP / 云账号。

设计文档：[docs/design.md](docs/design.md) · 协议：[docs/protocol.md](docs/protocol.md)

## 仓库里有什么

```
memolink/
  desktop/     # Tauri 2 + React（托盘、开机自启、悬浮便签、配对二维码）
  mobile/      # Flutter Android（列表编辑、扫码/粘贴 JSON 配对、TCP 同步）
  tools/       # 模拟手机客户端、防火墙脚本
  docs/        # 设计与协议
```

**不进 Git 的内容**（见 `.gitignore`）：

| 类型 | 说明 |
|------|------|
| `dist/`、`target/`、`build/`、`node_modules/` | 构建产物与依赖 |
| `pairing.json`、`*.db` | 本机配对密钥与便签库，禁止上传 |

安装包 / APK 请用 **GitHub Releases** 或 **Gitee 发行版** 附件发布，不要塞进源码仓库（体积大，且容易误传本地数据）。

## 前置条件

| 端 | 需要 |
|----|------|
| 桌面 | Node 18+、Rust、Windows |
| 手机 | Flutter 3.29+、Android SDK；与电脑同一 WiFi |
| 网络 | 关闭 AP 隔离；放行 TCP **47820**（可运行 `tools/add-firewall.bat`） |

## 桌面端

开发：

```bash
cd desktop
npm install
npm run tauri dev
```

打包：

```bash
cd desktop
# 若磁盘空间不足可指定：
# $env:CARGO_TARGET_DIR="D:\cargo-target\memolink-desktop"
npm run tauri build
```

产物一般在 `desktop/src-tauri/target/release/`（或你设置的 `CARGO_TARGET_DIR`）以及 Tauri bundle 目录；自行拷到本地 `dist/` 做发布，**不要 commit**。

## 手机端

```bash
cd mobile
flutter pub get
flutter build apk --release
# 产物：mobile/build/app/outputs/flutter-apk/app-release.apk
```

配对：扫电脑二维码；相机异常时用「粘贴 JSON」。

无真机时可用：

```bash
node tools/sim-phone.mjs
```

## 同步说明（MVP）

- 传输：局域网 TCP + 长度前缀 JSON（见 protocol.md）
- 冲突：LWW（`updatedAt` → `revision` → `originDeviceId`）
- 跨网 WebRTC：未实现（设计 v1.1）

## 常见问题

**手机连不上** — 同一 WiFi、IP 正确、防火墙放行 47820、二维码未过期。  
**便签看不见** — 托盘「显示/隐藏便签」；手机端确认「桌面显示中」。
