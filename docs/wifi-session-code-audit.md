# USBLinkMic 无线会话与控制链路静态代码审计报告

日期：2026-11-04  
分支：`zjx/wifi-auto-connect`  
范围：macOS (`macos/Core`, `macos/Support`, `macos/UI`, `macos/Contracts`) 与 Android (`android/app/...`) 双端控制与会话生命周期代码。  
性质：静态调用链审计与离线类型检查，非真机运行或设备验收。

---

## 1. 审计背景与用户反馈问题

在纯 Wi-Fi 模式下（不依赖 USB/ADB），原实现（4.0.17 Review-4）在实际运行中出现以下控制异常：
1. **停止不对称**：Mac 端点击“停止拾音”，Mac 端接收停止，但手机端仍持续处于录音状态（前台服务未停止、采音通知未消失）；而在手机端点击“停止拾音”，Mac 端能够同步停止。
2. **启动断链与 USB 依赖**：拔掉 USB 数据线后，在任一端点击“开始拾音”，均无法建立连接或直接报错，无法恢复采音。
3. **状态死锁**：手动停止后，由于控制通道随之断开或处于暂停标记（`pausedByUser`）阻塞，后续无论哪一侧重新触发，均陷入 `PAUSED_BY_USER`、`MAC_BUSY` 或无通道可发的死锁。

本审计针对双端源码进行了端到端静态调用链追踪与根本原因分析，并在不破坏原有安全握手与 USB 隔离的前提下完成修复。

---

## 2. 调用链追踪与根因分析

### 调用链 A：Mac 端在 Wi-Fi 模式下点击“开始拾音”

- **原调用链缺陷证据**：
  - `macos/Core/SessionController.swift:513`：`start(.microphone)` 无论当前传输通道为 USB 还是 Wi-Fi，均直接调度至 `startAudio(snapshot.settings.audio)`。
  - `SessionController.swift:708-725`：在 `startAudio` 内部，针对 Wi-Fi 的启动分支为：
    ```swift
    let targetHost = SettingsValidator.effectiveBindAddress(for: settings)
    if let target = selectedDevice() {
        let launch = settings.wifiLaunchArguments(targetHost: targetHost)
        _ = try? await adb.run(target.id, launch)
    } else {
        log("audio", "wifiWaitingHost", "等待 Wi-Fi 发送端连接，当前首选地址: \(targetHost)")
    }
    ```
  - **根因分析**：
    1. **ADB 强依赖**：当 USB 拔掉时，`selectedDevice()` 为空，Mac 无法通过 ADB 远程拉起手机；
    2. **虚假会话占用与 MAC_BUSY 冲突**：在没有 ADB 设备时，代码在 Mac 侧直接分配了 `OwnedSession(kind: .microphone)` 并设置 `status(.microphone, .connecting, "等待 Wi-Fi 发送端", ...)`。当手机随后发起正常的 `prepare` 请求时，Mac 端 `wifiPrepare` 检查：
       ```swift
       guard owned[.microphone] == nil, jobs[.microphone] == nil ... else { return .rejected(code: "MAC_BUSY") }
       ```
       由于 `owned[.microphone]` 已被 Mac 提前虚假占领，手机的合法请求被 Mac 自身无条件以 `MAC_BUSY` 拒绝！
    3. **缺乏从 Mac 到手机的触发命令**：原协议中 Mac 作为服务端仅被动监听，无任何命令通知手机发起会话。

- **修复方案与代码落地**：
  - 在 `SessionController.swift:514` 中，对 Wi-Fi 传输模式拦截分流至全新独立方法 `startWifiMicrophone(source:)`；
  - `startWifiMicrophone` 检查信任凭证与自动连接设置，若已存在已认证的手机控制通道，调用 `wifiService.requestStart()`；
  - 在 `WifiControlService.swift:197` 中实现 `requestStart()`，向手机端发送全新已签名服务端命令 `event-start`；
  - 若手机尚未连入局域网，Mac 明确将麦克风状态标记为 `connecting`（“等待已绑定手机连接”），绝不提前创建未确认的 `OwnedSession`，避免 `MAC_BUSY` 锁死；
  - 在 `startAudio` 中彻底剔除旧的 Wi-Fi ADB shell 调用分支。

---

### 调用链 B：Mac 端在 Wi-Fi 模式下点击“停止拾音”

- **原调用链缺陷证据**：
  - `SessionController.swift:554`：Mac 点击停止触发 `wifiService.endActiveSession(reason: "userStop")` 并发送 `event-stop` 到手机；
  - `android/.../WifiAutoConnector.kt:538`：手机接收到 `event-stop`，进入退出处理：
    ```kotlin
    "event-stop" -> {
        lastState = "ended"
        log("收到 Mac 停止事件: $m")
        break // 跳出会话循环
    }
    ```
  - 跳出循环后进入 `finally { closeSessionIfOwner(...) }`；
  - 在 `closeSessionIfOwner` 中：
    ```kotlin
    req.cancelled = true
    MicrophoneService.stopCapture(req)
    ```
    它只执行了底层 AudioRecord 的停止循环，**未调用 `Runtime.stop(context, req)`，也未停止 `MicrophoneService` 前台服务**！
  - 更隐蔽的缺陷在于 `MicrophoneService.kt:677-695`：
    ```kotlin
    override fun onDestroy() {
        val currentRequest = request
        if (currentRequest != null) {
            stopCapture(currentRequest)
            Runtime.onMicrophoneServiceStopped(currentRequest.session, currentRequest.error)
            if (Runtime.audioRequest === currentRequest) { // 陷阱！
                Runtime.audioRequest = null
                ...
                Runtime.update { it.copy(microphone = ModuleStatus()) }
            }
        }
    }
    ```
    在之前的回调中 `Runtime.onMicrophoneServiceStopped` 已经将 `Runtime.audioRequest` 置为 `null`！因此当 `MicrophoneService` 真正被销毁时，`Runtime.audioRequest === currentRequest` 判定为 `false`，导致 `Runtime.state` 中的 `microphone` 模块状态永远停留在 `RUNNING`，前台常驻通知也不会移除。

- **修复方案与代码落地**：
  - 在 `WifiAutoConnector.kt` 中封装统一的 `stopAudioService(reason: String)`：
    - 主动调用 `Runtime.stop(context, req, source = reason)`，确保向系统发送明确的 `stopService` Intent；
    - 在备用路径中直接重置 `Runtime.state` 并将麦克风状态与电平清零；
  - 在 `MicrophoneService.kt:onDestroy` 中增加显式 `stopForeground(STOP_FOREGROUND_REMOVE)`，保证通知栏图标立即移除；
  - 放宽状态重置条件为 `if (Runtime.audioRequest === currentRequest || Runtime.audioRequest == null)`，确保状态机无论回调先后顺序均正确归位为 `STOPPED`。

---

### 调用链 C：手机端点击“停止拾音”

- **原调用链缺陷证据**：
  - 手机端点击停止时，`onUserStoppedExplicitly()` 直接粗暴关闭了 TCP Socket 并使会话线程退出；
  - Mac 接收到 EOF 或底层断开，释放音频接收器；
  - 但由于长连接已断开，后续 Mac 无法再与手机通信；且 Mac 本地设置了 `pausedByUser = true`，手机重新建连时 Mac 会回复 `PAUSED_BY_USER` 错误，导致双方无法恢复。

- **修复方案与代码落地**：
  - 确立“**控制长连接与瞬态音频会话分离**”模型：
    - 用户停止拾音仅表示终止当前音频推流，不等于断开设备间双向可信通道；
    - 手机端点击停止时，在控制连接上发送已签名 `stop` 命令，同时调用 `stopAudioService()` 停止本地采音，但**保持 TCP 控制套接字与心跳保活循环继续运行**；
    - Mac 端收到 `stop` 命令后，安全结束音频接收器，记录 `pausedByUser = true`，回复 `stopped`，控制通道连接维持不变。

---

### 调用链 D：停止后在任意一侧再次点击“开始拾音”

- **原调用链缺陷证据**：
  - 原先停止会切断控制通道，手机需重新进行 NSD 发现与 TCP 建连；
  - 建连后手机发起的首个 `prepare` 报文通常未带 `userInitiated`，Mac 因之前停留在 `pausedByUser = true`，直接返回 `PAUSED_BY_USER` 错误拒绝；
  - 在 Mac 侧，由于无触发手机机制，用户点击开始只能在界面上干等。

- **修复方案与代码落地**：
  - **Mac 侧再次点击开始**：
    - `startWifiMicrophone` 将本地 `pausedByUser` 置为 `false`；
    - 通过长连接发送 `event-start`；
    - 手机端收到 `event-start`，清空本地 `pausedByUser = false`，并在已有连接上直接发送 `prepare(userInitiated = 1)`；
  - **手机侧再次点击开始**：
    - `onUserStartedExplicitly` 直接通过活跃长连接发送 `prepare(userInitiated = 1)`；
    - Mac 端 `WifiControlService` 解析到 `userInitiated == true` 时，自动重置 `pausedByUser = false` 并放行；
    - `SessionController.wifiPrepare` 检查若有残留正在停止的任务（`stopping.contains(.microphone)`），主动等待其完成，彻底杜绝竞争拒绝；
    - Mac 分配音频端口并返回 `prepared`；手机收到后更新 `audioToken` 并拉起 `MicrophoneService` 建立音频推流。

---

## 3. 控制通道与音频传输解耦架构

```
+--------------------------------------------------------------------------------+
|                                Control Plane                                   |
| (Persistent Authenticated TLS/P256-HMAC TCP Channel, Port dynamic via Bonjour)  |
|                                                                                |
|   Mac (WifiControlListener)  <===================>  Android (WifiAutoConnector) |
|      - event-start (Mac -> Phone)                     - prepare (Phone -> Mac) |
|      - event-stop  (Mac -> Phone)                     - stop    (Phone -> Mac) |
|      - state/error (Mac -> Phone)                     - status  (Phone -> Mac) |
|                                                                                |
|   * Kept alive during idle, paused, streaming, and stop cycles.                |
+--------------------------------------------------------------------------------+
                                       |
                     Trigger prepare / prepared handshake
                                       v
+--------------------------------------------------------------------------------+
|                                Audio Plane                                     |
|           (Ephemeral Raw PCM over TCP, Port allocated per session)              |
|                                                                                |
|   Mac (AudioReceiver)        <-------------------   Android (MicrophoneService)|
|      - Dynamic Port                                   - AudioRecord Capture    |
|      - Token Handshake                                - Length-prefixed PCM    |
|                                                                                |
|   * Allocated on Start; Torn down completely on Stop.                          |
+--------------------------------------------------------------------------------+
```

---

## 4. 详细修改文件与代码证据

| 文件 | 变更位置 | 审计证据与说明 |
| :--- | :--- | :--- |
| `macos/Core/SessionController.swift` | L514, L708, L1670-1696, L1755 | 新增 `startWifiMicrophone`；剥离 Wi-Fi 下对 ADB `startAudio` 的依赖；准备接收器前等待 pending stopping 任务结束。 |
| `macos/Support/WifiControlService.swift` | L100, L197, L355, L371, L427 | 暴露 `hasAuthenticatedConnection` 与 `authenticatedPhoneID`；实现 `requestStart()` 发送 `event-start`；`prepare` 支持解析 `userInitiated` 并重置 `pausedByUser`。 |
| `macos/UI/MicrophoneWorkspaceView.swift` | L113-126 | 设备名显示在 Wi-Fi 模式下优先采用已连接手机名或首个已信任手机名，避免 USB 拔出时显示默认占位符。 |
| `macos/UI/MenuBarConsoleView.swift` | L58-71 | 菜单栏悬浮面板在 Wi-Fi 模式下对已连接/已信任手机名称进行准确绑定，未连接时标明“等待 Wi-Fi 手机”。 |
| `macos/UI/RootView.swift` | L330-340 | 侧边栏底部设备摘要增加 Wi-Fi 模式展示，不再死锁显示“等待手机连接”。 |
| `android/.../WifiAutoConnector.kt` | L201, L300, L332, L538, L725 | `ActiveSession.sessionID` 声明为 `@Volatile var`；实现 `stopAudioService` 保证前台采音彻底停止；控制循环接收 `event-start` 与 `prepared` 并维持保活连接；`onUserStartedExplicitly` 支持直接发送 `prepare`。 |
| `android/.../MicrophoneService.kt` | L677-695 | `onDestroy` 增加显式 `stopForeground(STOP_FOREGROUND_REMOVE)`，放宽状态机重置条件，防止通知常驻与状态假死。 |
| `android/.../MainActivity.kt` | L156-166 | `startAccepted` 处理重入/陈旧音频请求，如前一请求已取消则主动替换，避免假死报 `AUDIO_BUSY`。 |
| `contracts/wifi-auto-connect-v1.md` | L179, L187-193 | 增加 `event-start` 控制指令契约；新增第 7.2 节“控制通道与音频会话分离”协议规范。 |

---

## 5. 潜在边界、客观物理限制与非回归确认

1. **Android 前台麦克风系统限制 (Physical/OS boundary)**：
   - 根据 Android 14+ / targetSdk 34+ 规范，应用在后台/无前台 Activity 时禁止拉起麦克风前台服务（`ForegroundServiceStartNotAllowedException`）。
   - 本修复在 Android App 处于前台或处于合法可启动窗口期内工作正常；若手机屏幕长久熄灭、App 被系统彻底杀掉或被后台冻结，Mac 单向发送 `event-start` 无法突破 Android 系统的安全防线。用户必须确保手机端 App 打开或至少在前台允许的生命周期内。
2. **Wi-Fi 网络隔离 (Network boundary)**：
   - 依赖局域网双向组播/TCP 通信。若路由器开启了 AP 隔离（访客网络），Bonjour 广播和 TCP 连接无法建立，此属网络物理隔离，代码无法绕过。
3. **USB 链路无回归**：
   - 审查确认：USB 麦克风传输路径、USB 供网（NCM）以及反向供网（Reverse Tethering）均由独立的 `startUsbMicrophone` / `startNetworkSharing` 和守护进程处理，本次改动严格限定在 Wi-Fi 传输分流内，未变动任何 USB 或网络共享模块代码。

---

## 6. 验证执行与状态

- **Swift 离线类型检查**：
  - 执行命令：`swift build`
  - 结果：通过（exit code 0，耗时 3.52s，产物无警告）。
- **Android 离线类型检查**：
  - 执行命令：`./android/gradlew -p android :app:compileDebugKotlin --console=plain`
  - 结果：通过（exit code 0，`BUILD SUCCESSFUL in 5s`）。
- **用户自测与验收建议**：
  - 请按照 [wifi-auto-connect-testing.md](wifi-auto-connect-testing.md) 中的【用例 3：手动停止与双向恢复】进行真机拔线验收。
