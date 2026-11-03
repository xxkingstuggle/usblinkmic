# Wi-Fi 自动连接：现场审查与实施计划

日期：2026-11-04。状态：首轮审查 7 项返工及测试隔离整改已全部完成。双端代码实现与离线单元测试全部通过（Mac 39 项测试 0 失败，Android 12 项测试 0 失败）。候选安装包（版本 4.0.17，Review-2）已完成构建与自签名，暂存在 `artifacts/agy-wifi-auto-connect/review-2/4.0.17/`；协议规范见 `contracts/wifi-auto-connect-v1.md`；待用户真机与真实局域网/热点场景验收。

## 实施进展记录 (Implementation Status)

- **Mac 端实现**：
  - `macos/Contracts/Models.swift`：增加 `wifiRevision = 1`、`bonjourServiceType = "_usblinkmic._tcp"`、`wifiAutoConnect` 开关模型（向下兼容解码）、`WifiAutoSnapshot`、`WifiPairPrompt`、`TrustedPhoneInfo` 与配对授权动作。
  - `macos/Support/WifiCrypto.swift`：实现 P-256 ECDH 密钥交换、HKDF/HMAC-SHA256、6 位 SAS 校验码、音频 token 派生及常量时间比较。
  - `macos/Support/WifiTrustStore.swift`：基于 `~/.usblinkmic/wifi-trust.json`（0600 权限）管理稳定 Mac 身份及可信手机记录。
  - `macos/Support/WifiControlService.swift`：实现纯内存/MainActor 控制状态机，覆盖 hello、配对提问、互相鉴权、音频会话准备、状态同步、单端停止及防重放/防爆破限流。
  - `macos/Core/WifiControlListener.swift`：基于 NWListener 的 TCP 监听与 Bonjour 服务广播（支持隔离回环模式）。
  - `macos/Core/SessionController.swift`：整合 `WifiSessionHost`，支持自动发现准备、手动停止暂停、防旧回调抢占。
  - `macos/UI/`：MicrophoneWorkspaceView 与 MenuBarConsoleView 增加配对提示横幅（含 6 位校验码对比、允许/拒绝）及已连接 Wi-Fi 手机名称显示；DevicesAndLogsView 增加配对与可信设备管理列表。
  - **离线测试**：XCTest 96 个测试全部通过（含 25 个 WifiControlService 状态机测试、5 个密码学向量测试、4 个回环 Socket 隔离测试、3 个 WifiLaunchCommandTests）。
- **Android 端实现**：
  - `android/app/build.gradle.kts`：版本升级为 `versionCode = 40017`，`versionName = "4.0.17"`。
  - `android/app/src/main/java/com/zjx/usblinkmic/contracts/Models.kt`：增加 `WIFI_REVISION = 1`、`BONJOUR_SERVICE_TYPE`、`wifiAutoConnect` 设置、`WifiAutoSnapshot`、`DiscoveredMac`、`TrustedMacInfo`、`WifiAutoPhase` 等。
  - `android/app/src/main/java/com/zjx/usblinkmic/support/WifiCrypto.kt`：与 Mac 端完全一致的 P-256、HKDF、HMAC、SAS 密码学引擎。
  - `android/app/src/main/java/com/zjx/usblinkmic/support/WifiTrustStore.kt`：SharedPreferences 持久化稳定手机身份与可信 Mac 列表。
  - `android/app/src/main/java/com/zjx/usblinkmic/platform/WifiAutoConnector.kt`：Android NSD 自动发现 `_usblinkmic._tcp`、发起配对/认证/会话准备、网络重连与用户手动停止暂停。
  - `android/app/src/main/java/com/zjx/usblinkmic/MainActivity.kt` & `LinkMicScreen.kt`：整合自动发现与配对横幅（6 位对比码）、发现列表、可信设备解除。
  - **离线测试**：JUnit 19 个单元测试全部通过（含 5 个跨平台向量与回环状态机测试、14 个基础支持测试），`lintDebug` 0 错误。
- **打包与验证**：
  - `scripts/package.sh`：支持动态版本号 `4.0.17`，在 Mac `Info.plist` 中补充 `NSBonjourServices: ['_usblinkmic._tcp']` 及 `NSLocalNetworkUsageDescription`。
  - 产物在 `artifacts/agy-wifi-auto-connect/4.0.17/` 生成并通过 `verify-release.py`、`codesign`、`apksigner` 全部校验。
  - 严守安全红线：未触碰 `/Applications/USB LinkMic.app`，未杀或干扰正在运行的 PID 21927，未连接真实设备 ADB。

## 结论 (Verdict)

**needs-attention — 目标可实现；现有代码只完成了 Wi-Fi 音频传输，需要新增设备发现、可信会话及自动启动/重连编排。**

目标体验：首次完成系统授权并确认这对设备后，手机与 Mac 位于可互通的同一局域网，只需打开两端 App，自动连接并拾音。日常使用不输入 IP、不输入配对码、不依赖 USB/ADB。支持普通 Wi-Fi，以及这台 Android 手机开热点、Mac 加入热点。

“同一 Wi-Fi”以局域网实际可互通为前提；不能承诺穿透访客网络隔离。首次系统授权和首次确认设备不算日常重复操作。

## 事实清单 (Irreducible Facts)

- **[evidence / physics]** 本次 `adb devices -l` 为空。现场先出现“等待 Wi-Fi 发送端”，随后界面恢复“正在向 Mac 传输音频”，累计超过 4,700 帧；后续日志为 5,680 包且有新接收字节。证明当前网络中的 Wi-Fi 音频可以脱离 USB 传输。不知道手机端当时由什么操作重新发起，不能称为自动发现通过。
- **[evidence / convention]** Mac 启动时只有恢复、刷新和监控，没有 Wi-Fi 自动发现/自动开始会话。见 `macos/Core/SessionController.swift:162`。
- **[evidence / convention]** Mac 所谓自动同步依赖 ADB `am start`；没有设备时退回提示手机填写 IP。见 `macos/Core/SessionController.swift:716`。
- **[evidence / convention]** Android `onCreate/onStart` 加载配置、显示 UI；Wi-Fi 启动来自 `UserAction.StartWifi` 或受保护的 ADB 入口。没有 NSD/Bonjour 发现。见 `android/app/src/main/java/com/zjx/usblinkmic/MainActivity.kt:40`、`:144`。
- **[evidence / convention]** Android 按保存的 `wifiHost` 建立 TCP；采集异常后结束当前服务，没有发现新地址并重试的流程。见 `android/app/src/main/java/com/zjx/usblinkmic/platform/MicrophoneService.kt:484`、`:637`。
- **[evidence / convention]** Mac 已有 NWListener 和 PCM 处理，可复用；Wi-Fi 断流时继续监听，单独补 Mac 重试不足以恢复手机发送。见 `macos/Core/AudioReceiver.swift:110`、`macos/Core/SessionController.swift:781`。
- **[evidence / physics]** Android 麦克风前台服务的启动受界面可见性和系统权限限制；不能把“打开两端 App”扩张为“被强制停止后仍远程唤醒”。[Android 官方限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start#wiu-restrictions)。
- **[evidence / convention]** 当前 Android 控制服务只绑定 `127.0.0.1`，其会话约定是 loopback/ADB，不能直接改成全网监听。见 `android/app/src/main/java/com/zjx/usblinkmic/platform/Runtime.kt:278` 和 `contracts/connection-control-v1.md`。

## 攻击点 (Attack Points, by severity)

1. **[P1 / inference] 把“普通 Wi-Fi 能发现”等同于“手机作为热点也能发现”。** Android 热点接口不一定与普通已连接 Wi-Fi 的 NSD 行为一致，多网卡/VPN 也可能给出错误地址。最便宜的证伪实验：先做最小 Mac 服务发布 + Android 发现探针，在普通路由器和这台手机热点各跑一次，必须取到可连接端点并完成随机挑战回包；同时覆盖开启现有 VPN、多个网卡和改变热点地址。解析出 IP 或本机自发现不算通过。当前 ping 热点地址未成功，但现场有真实音频流，因此不能只凭 ping 判定网络或发现机制失败。
2. **[P1 / evidence] 只增加发现，生命周期和停止语义仍缺失。** 手机先开、Mac 后开，或手机录音失败后，现有代码不会自主发现重试；只在 onResume 里加 StartWifi 又可能重复启动，或者把用户停止覆盖掉。证伪实验：两种启动顺序、连续 Activity 重建、网络闪断、手动停止；每次只允许一个录音服务和一个有效音频会话，停止后本次打开期间不得自行恢复录音。
3. **[P1 / evidence + inference] 把“发现同名服务”当成“认出了自己的设备”。** 当前 Wi-Fi 配对码为空时不校验 token；自动选择首个响应者会连错 Mac，也可能让无关设备占用会话。证伪实验：第二台同名 Mac、伪造/重放发现响应、旧会话迟到和协议不兼容客户端。必须只自动连接已绑定身份；未认证连接不能启动采音、抢占正在传输的连接或触发音频输出。

## 幸存结论 (What Survives)

- 不需要互联网服务器或账号；发现、连接和音频传输可以在本地完成。
- 保留 Android 主动连接 Mac 的方向，复用当前 PCM 编码、接收和 BlackHole 输出。
- 首选 Mac Bonjour 发布、Android NSD 发现。官方 API 支持发布/解析服务端口和地址，用户无需维护 IP。[Apple NWListener](https://developer.apple.com/documentation/network/nwlistener)、[Android NSD](https://developer.android.com/develop/connectivity/wifi/use-nsd)。
- 只有真实热点实验显示 NSD 路径不可用时，才补局域网内有界 UDP 发现（优先热点网关定向探测），并复用同一身份认证和连接状态机；不预先增加多套并行发现系统，不扫描整个网段。

## 修改建议 (Changes)

### 0. 先做决定技术路线的真机实验

建立最小发现探针，输出“找到服务 → 解析端点 → 双向握手成功”三段证据。覆盖普通 Wi-Fi、Android 热点、热点重开/IP 改变和 VPN 开启。需要在手机上安装包含探针的构建；安装后拔线验收，开发时安装方式不成为日常使用依赖。

只有这一步通过后，才把发现机制接入完整录音流程。不能用 Mac 自测、模拟器或编译成功替代热点实测。

### 1. 补独立的发现与会话准备入口

- Mac 的 Wi-Fi 自动连接模式启动后，先运行轻量 LAN 会话监听并发布服务，避免尚未收到手机请求就持续创建音频输出管线。发现入口与现有音频接收器分离，服务端口从实际监听结果发布。
- Android App 可见时开始发现，解析服务的实际端点；不用保存的旧 IP 覆盖发现结果。设备名只作展示，绑定关系使用稳定设备身份。
- 首次确认这对设备并保存信任，之后自动认证。发现广播只含协议/能力等非秘密字段；凭据不得放入 TXT、UDP 广播或日志。可信会话握手的认证、重放防护与密钥保存方式先形成双方契约再实现。
- LAN 会话负责准备、停止、状态和掉线通知；Mac 准备好接收器后才让手机采音。保留现有 USB 控制服务的 loopback 边界，不把旧控制端口直接暴露到 LAN。
- 音频参数、发现修订、会话身份分别检查；协议不兼容明确提示两端升级，不进入无限重试。

### 2. 接入自动启动与重连状态机

`等待网络 → 正在发现 → 等待首次确认/系统权限 → 准备会话 → 连接音频 → 收到真实帧 → 传输中`

- 两端启动顺序任意；首次绑定后默认启用这对设备的自动连接，并可关闭。
- 连网变化时丢弃旧端点并重新发现；重试退避、有上限速率、可取消，不在主线程轮询，不高频无限写日志。
- 用当前会话编号/代际隔离旧回调，防止迟到的握手或停止取消新会话。
- 手动“停止”暂停本次打开期间的自动拾音；重新启用或下次冷启动时按保存的自动连接设置处理。普通 onResume、旋转或重新发现不撤销暂停。
- 已从前台合法启动的录音按前台服务生命周期继续；后台/锁屏后的首次启动或重新启动遵守 Android 限制，不能把抑制系统限制作为实现方式。
- 两端 UI 展示同一会话状态；只有真实 PCM 到达才显示“传输中”。Mac 的设备名称和在线状态应来自 Wi-Fi 身份，不能仍显示“等待 USB 手机连接”。IP/手动端口移入高级诊断区。

### 3. 双端适配与检查边界

预计改动：`macos/Core` 新发现/会话模块与 SessionController 编排、`macos/Contracts` 和 Android contracts 的协议/状态、Android platform 发现/重连模块、MainActivity 生命周期接入、两端设置与 UI、`scripts/package.sh` 的 Bonjour 声明及说明文案。新增协议说明放在 `contracts`，明确与 USB 控制协议分开。

当前 Android targetSdk=36；按实际 target/系统执行权限适配，不为 SDK36 盲目请求只适用于更高 target 的新权限。Mac 检查本地网络授权、Bonjour 声明和拒绝后的可恢复提示。[Android 本地网络权限](https://developer.android.com/privacy-and-security/local-network-permission)、[Apple Bonjour 声明](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSBonjourServices)。

不在本计划中改音频缓冲、USB 供网、反向供网或全局 VPN/路由设置。保留本会话前一轮的两处 Wi-Fi 启动修复和回归测试。

### 4. 验收标准

以下时间均为拟定验收目标，尚无测量结果；从网络可用、权限已授予且双方 App 进入可工作状态开始计时。

| 场景 | 通过条件 |
|---|---|
| 普通 Wi-Fi / 这台 Android 热点 | 各自完全断开 USB，ADB 列表为空，Mac 先开与手机先开各至少 5 次，10 秒内收到首个真实 PCM 帧；不填写 IP/配对码，不点击“开始拾音” |
| 清除旧端点缓存 | 已绑定身份保留，但删除缓存 IP；仍能发现并连接，证明不靠记住地址 |
| 重开热点 / IP 改变 | 重新发现，网络稳定后 20 秒内恢复实际帧；不重用旧地址，不要求重开两个 App |
| 手机/Mac App 分别重启 | 另一端保持运行，遵守启动权限后自动恢复；最多一个有效会话 |
| 主动停止 | 两端停止状态一致；在持续发现、重复回调和网络重连下保持暂停至少 60 秒，不擅自重启 |
| 多设备/同名/伪造响应/旧协议 | 只连已信任的目标；无关设备不得触发采音或抢占；不兼容版本有明确状态 |
| 权限拒绝、VPN、多网卡、断网 | 不把权限失败显示为“没找到设备”；不选择 TUN/USB 地址；网络不可达时说明失败，允许之后恢复 |
| 手机锁屏与后台 | 已合法开始的录音及中断恢复分别实测；不能推断可任意从后台重新启动录音 |
| 数据真实有效 | 接收帧数持续增长、电平有响应，并检查 BlackHole 端实际输入；发现成功或 TCP connected 不等于麦克风验收 |
| 回归 | 现有 USB 音频、Wi-Fi 手动连接及 USB 两个供网方向保留；必要测试不得用改变原断言来通过 |

先给发现和状态机建立失败用例，再实现功能；两端成套构建、安装并真机验收。已有独立日志保留测试失败另行记录，不混入本功能的通过数量。

## 未解疑问 (Open Questions)

- **这台 Android 当热点时，系统 NSD 能否发现 Mac 发布的服务？** 尚未运行新双端探针；会决定是否需要有界 UDP 发现。现有音频成功不回答这个问题。
- **推荐的首次一次性设备确认体验：** 默认计划采用“首次确认设备，之后自动”，不要求用户记住或重复输入 IP/码。如果要求连首次确认都没有，需要另外定义如何可靠选定自己的 Mac，不能简单选择第一个广播响应者。
