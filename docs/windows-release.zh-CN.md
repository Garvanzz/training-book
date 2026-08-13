# Windows 客户端：启动、验收与打包

本文针对 Windows 10/11 x64 的个人使用版本。客户端默认连接本机服务端；正式部署时必须显式传入服务端地址，不能依赖 `127.0.0.1`。

## 一次性前置条件

- Windows 10/11 x64。
- Flutter stable SDK（当前项目使用 `D:\tools\flutter`）。
- Visual Studio 2022，并安装「使用 C++ 的桌面开发」和「C++ ATL for x86 and x64（最新 MSVC）」。
- 后端 PostgreSQL、迁移和 Owner 初始化已完成。
- 首次执行 `flutter pub get` 时需要能下载原生依赖。`sqflite_common_ffi` 会取得 SQLite x64 DLL；`media_kit_libs_windows_video` 会随 Flutter Release 包带入视频播放所需库。

## 启动本地开发版

先在一个 PowerShell 窗口启动后端：

```powershell
cd D:\self\training-book\backend
..\.venv\Scripts\python.exe -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

在另一个窗口检查服务健康状态。返回 `status : ok` 后再启动客户端：

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health

cd D:\self\training-book\apps\client_flutter
D:\tools\flutter\bin\flutter.bat pub get
D:\tools\flutter\bin\flutter.bat run -d windows
```

默认地址是 `http://127.0.0.1:8000`。若后端在局域网或服务器上，使用 HTTPS 地址重新运行：

```powershell
D:\tools\flutter\bin\flutter.bat run -d windows --dart-define=API_BASE_URL=https://api.example.com
```

`API_BASE_URL` 不含末尾 `/`。发布给其他设备时禁止使用 HTTP 和 `127.0.0.1`；应使用受信任证书的 HTTPS 域名。

## Release 构建与交付

关闭所有正在运行的 `training_book.exe` / `flutter run` 实例，避免锁定构建产物：

```powershell
cd D:\self\training-book\apps\client_flutter
D:\tools\flutter\bin\flutter.bat analyze
D:\tools\flutter\bin\flutter.bat test
D:\tools\flutter\bin\flutter.bat build windows --release --dart-define=API_BASE_URL=https://api.example.com
```

可交付目录为：

```text
build\windows\x64\runner\Release\
```

将该目录**整体**压缩或安装；不要只复制 `.exe`。目录内的 `data\`、Flutter DLL、SQLite DLL、视频播放器 DLL 都是运行所需文件。首次交付前，在一台未安装 Flutter 的 Windows x64 机器上解压并验证以下事项：

1. 应用标题为 `Training Book`，图标与版本信息正确。
2. 可登录、进入离线预览，并能在断网状态查看本地数据。
3. 可打开一张图片和一个 MP4 动作资料；视频能播放、暂停和关闭。
4. 可完成一次训练记录；恢复网络后确认同步状态变化。
5. 关闭并重新打开应用后，已登录状态与本地训练数据仍在。

当前输出是便携式 Release 目录，不是已签名的 MSI/MSIX 安装包。对外分发前仍应选择安装器方案、申请代码签名证书并建立升级机制；未签名可执行文件可能触发 Windows SmartScreen。

## 失败排查

| 现象 | 优先检查 |
| --- | --- |
| 登录提示无法连接本机服务 | `Invoke-RestMethod http://127.0.0.1:8000/health`；确认后端终端没有报错。 |
| `build windows` 提示文件被占用 | 退出桌面客户端、IDE 中的调试会话，再重新构建。 |
| `sqlite3.x64.windows.dll` 下载超时 | 网络无法访问 GitHub Release。恢复网络后执行 `flutter pub get` 或 `flutter test`；这是离线数据库的原生前置资源。 |
| `mpv-dev-*.7z Integrity check failed` | `media_kit` 的播放器归档下载不完整。关闭构建进程后清理 Flutter 的**生成目录**并重新执行 `flutter pub get`、`flutter build windows --release`；不要修改或删除应用源文件与依赖声明。 |
| 视频没有播放 | 确认从完整 Release 目录启动，且没有漏掉视频播放器 DLL。 |
| 其他电脑无法连接 API | 检查 `API_BASE_URL`、HTTPS 证书、防火墙及服务端 CORS/反向代理配置。 |

## 数据与安全边界

- 不要将后端 `.env`、数据库文件、媒体源文件或 Token 放进安装包或提交到仓库。
- Windows 本地数据仅用于该 Windows 用户。卸载/清理用户数据前先实现并验证备份与恢复流程。
- 个人版可使用 Owner 审核动作库；未来多用户部署时，媒体必须改为受权限控制的对象存储与短时访问 URL。
