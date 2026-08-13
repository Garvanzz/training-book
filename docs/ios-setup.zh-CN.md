# iOS 端:零成本自用方案上手

> 目标:用一台 Mac + Xcode + 免费 Apple ID,把 Training Book 装到自己的 iPhone 上,
> 不买开发者账号、不上 App Store。
>
> 前提约束(苹果硬性限制,无法绕过):
> - iOS 构建只能在 macOS 上进行;Windows 无法编译 iOS 包。
> - 免费 Apple ID 真机签名 7 天过期,到期后连上 Mac 重新 build 一次即可,数据不丢。

## 1. 前置条件

- Mac(macOS 14+),已装 Xcode(≥15,`xcode-select --install`)
- Flutter stable SDK(与 Windows 端同一版本即可,文档以 `D:\tools\flutter` 为 Windows 参照,Mac 上安装路径不同)
- 自己的 iPhone + 数据线
- Apple ID(免费即可)

## 2. 一次性:生成 iOS 工程

在 Mac 上,把仓库拷过去后:

```bash
cd apps/client_flutter
flutter create . --platforms=ios
```

这会生成 `ios/` 目录并保留现有 `lib/` 代码,不触碰任何现有文件。

## 3. 依赖(已就绪)

`pubspec.yaml` 已包含 iOS 视频播放原生库:

```yaml
media_kit_libs_ios_video: ^1.0.0
```

执行:

```bash
flutter pub get
cd ios && pod install && cd ..
```

## 4. 配置 Info.plist

编辑 `ios/Runner/Info.plist`,在 `<dict>` 内加入以下键(内网/本地 HTTP 后端必需):

```xml
<!-- 允许访问局域网 IP 的明文 HTTP(自用内网后端) -->
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>

<!-- iOS 14+ 访问局域网设备时的权限说明 -->
<key>NSLocalNetworkUsageDescription</key>
<string>训练数据需要连接到你自己的训练服务端。</string>

<!-- 应用显示名 -->
<key>CFBundleDisplayName</key>
<string>训练簿</string>
```

## 5. 让手机连上你的后端

手机和 Windows 后端必须在同一局域网。手机**不能**用 `127.0.0.1`(那是手机自己)。

1. 在 Windows 上查后端机器的局域网 IP:
   ```powershell
   ipconfig   # 找 IPv4 地址,例如 192.168.1.100
   ```
2. 后端以 `--host 0.0.0.0` 启动(监听局域网):
   ```powershell
   ..\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
3. Windows 防火墙放行 8000 端口(专用网络)。
4. 构建时把 API 地址传进去(不含末尾 `/`):
   ```bash
   flutter run -d <iphone> --dart-define=API_BASE_URL=http://192.168.1.100:8000
   ```

## 6. 真机运行(免费 Apple ID)

1. iPhone 用数据线连 Mac,`flutter devices` 应能看到设备。
2. Xcode 打开 `ios/Runner.xcworkspace`:
   - Runner target → Signing & Capabilities
   - Team 选自己的 Apple ID(首次会提示创建 "Personal Team",免费)
   - Bundle Identifier 保持默认即可
3. 返回终端运行第 5 步的命令。
4. 手机上首次安装时:**设置 → 通用 → VPN 与设备管理 → 信任开发者**。

## 7. 7 天到期续签(日常维护)

免费签名有效期 7 天。到期后 app 打开会闪退,此时:

1. 连上 Mac
2. 重新执行一次第 5 步的 `flutter run`(或 `flutter build ios --debug --dart-define=...` 后 Xcode 安装)

数据(登录态、SQLite、离线队列)保存在应用沙盒,重签不丢失。

## 8. 常见问题

| 现象 | 处理 |
|---|---|
| 登录提示连不上服务 | 手机与后端是否同一局域网;后端是否 `--host 0.0.0.0`;Windows 防火墙是否放行;`API_BASE_URL` 是否传了局域网地址 |
| 请求超时/被拒但网页能开 | iOS 本地网络权限被拒:设置 → 隐私 → 本地网络 → 打开训练簿 |
| 视频打不开 | 确认第 3 步 `pod install` 成功(缺 `media_kit_libs_ios_video` 时无声音/黑屏) |
| 登录后闪退 | 7 天签名过期,重签(第 7 节) |
| 注册按钮不出现 | 后端 `.env` 未设 `REGISTRATION_ENABLED=true` |
| App 显示英文名 | `CFBundleDisplayName` 未生效,检查第 4 步 |

## 9. 验收

复用 [windows-acceptance.zh-CN.md](windows-acceptance.zh-CN.md) 的 A–E 场景,在 iPhone 上把离线训练闭环(D 场景)完整跑一遍——这是 iOS 与 Windows 唯一有差异的部分。
