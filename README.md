# USB LinkMic

手机就在手边，麦克风和网络也都在。接到 Mac 上，能不能直接用起来？

USB LinkMic 做的就是这件事。插一根 USB 线，把 Android 手机当作 Mac 的麦克风；需要联网时，可以让手机给 Mac 供网，也能反过来把 Mac 的网络接给手机。三项功能放在同一个窗口里，选设备、开始、看状态、停止，不用在终端来回敲命令。

[下载最新版](https://github.com/xxkingstuggle/usblinkmic/releases/latest) · [安装与使用](docs/install.md) · [从头看它怎么工作](docs/how-it-works.md)

<img src="assets/branding/mac-app-icon-prepared.png" width="112" alt="USB LinkMic 图标" />

手机麦克风收到的声音，可以先在 Mac 上试听。要在会议、录音或直播软件里使用，就把输出交给 BlackHole，再在那个软件里选择 BlackHole 作为输入。USB 和同一可信局域网内的 Wi-Fi 都有对应入口。

两个供网方向也分得很清楚。手机给 Mac 供网，走 USB 网卡与系统共享能力；Mac 给手机供网，走手机端的 VPN 和 Mac 上的转发程序。它们一次只开一个方向，切换前先把上一项停好。

这里有个决定需要讲清楚。界面的「已连接」表示实际 USB 共享、地址和链路，或者 VPN 与转发通道已经就绪。它不拿几个公网网站的探测结果决定要不要拆掉连接。能不能访问你要用的网站，打开它试一下就知道。

目前提供 macOS 26 及以上、Apple Silicon 的安装包。Android 音频支持 8.0 及以上；手机给 Mac 的自动 NCM 共享需要 Android 11 及以上，而且要看手机系统有没有开放对应能力。并不是插上任意一台 Android 就都能跑。

普通使用不用装 Xcode、Android Studio 或 Java。Mac 包里带了配套 APK、ADB 和转发运行时，连接手机后会检查配套版本。录音、VPN 和 USB 调试的系统授权仍由你自己确认，应用不会替你点允许。

2026 年 10 月 17 日，维护者反馈当前安装版使用正常，确认可以发布并清理旧项目。这是当前设备上的使用反馈，不是对所有机型、ROM 和网络环境的保证。更完整的逐项验收记录仍保留在[验收矩阵](docs/acceptance.md)里。

新版保留独立 Git 历史。早期按净室方式重建，后续修复经授权参考过旧实现，所以这里不再标榜严格净室。旧项目退出日常维护，新版以当前仓库的 main 和 Release 为准。

想自己编译，可以看[开发说明](docs/development.md)。第三方组件和许可放在[依赖记录](docs/dependencies.md)里。遇到问题时，把操作步骤和应用日志一起留下，比一句「连不上」更容易找到原因。
