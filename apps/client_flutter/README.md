# Training Book Flutter 客户端

Windows 是当前首发平台；iOS 作为后续目标。客户端提供登录、动作库维护、计划画布、训练记录、媒体查看和离线数据能力。

## 常用命令

```powershell
cd D:\self\training-book\apps\client_flutter
D:\tools\flutter\bin\flutter.bat pub get
D:\tools\flutter\bin\flutter.bat analyze
D:\tools\flutter\bin\flutter.bat test
D:\tools\flutter\bin\flutter.bat run -d windows
```

后端默认地址是 `http://127.0.0.1:8000`。使用远程环境时，以 `--dart-define=API_BASE_URL=https://...` 显式提供地址。

完整的 Windows 启动、验收、Release 构建和排障说明见 [Windows 发布手册](../../docs/windows-release.zh-CN.md)。

不要重新运行 `flutter create` 覆盖现有 `windows/` 或领域代码；平台宿主已经纳入项目维护。
