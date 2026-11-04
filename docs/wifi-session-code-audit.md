# USBLinkMic 无线会话与控制链路静态代码审计报告

日期：2026-11-04  
分支：`zjx/wifi-auto-connect`  
范围：macOS (`macos/Core`, `macos/Support`, `macos/UI`, `macos/Contracts`) 与 Android (`android/app/...`) 双端控制与会话生命周期代码。  
性质：静态调用链审计与离线类型检查，非真机运行或设备验收。

---

## 1. 审计背景与用户现场反馈

### 1.1 用户实际观察到的现象 (User Observations)
在纯 Wi-Fi 模式下（不依赖 USB/ADB），原 4.0.17 Review-4 候选版本在用户端反馈了以下控制异常：
1. **停止不对称**：Mac 端点击“停止拾音”，Mac 端接收停止，但手机端仍持续处于录音状态（前台服务未停止、采音通知未消失）；而在手机端点击“停止拾音”，Mac 端能够同步停止。
2. **启动断链与 USB 依赖**：拔掉 USB 数据线后，在任一端点击“开始拾音”，均无法建立连接，无法恢复采音。
3. **状态死锁**：手动停止后，由于控制通道随之断开或处于暂停标记（`pausedByUser`）阻塞，后续无论哪一侧重新触发，均陷入 `PAUSED_BY_USER`、`MAC_BUSY` 或无通道可发的死锁。

### 1.2 静态推导得出的根因 (Static Deductions)
通过对双端源码的端到端调用链推演，审计确认了以下具体根因：
- Mac 端 `start(.microphone)` 盲目进入遗留的 `startAudio` 路径，该路径依赖 `adb shell am start`；拔除 USB 时无 ADB 设备，Mac 提前创建 `OwnedSession` 占位，导致后续手机的合法 `prepare` 请求被 Mac 自身的 `MAC_BUSY` 校验拒绝。
- Mac 端发送 `event-stop` 后，Android 端 `closeSessionIfOwner` 仅调用了底层 AudioRecord 停止，未调用 `Runtime.stop(context, req)`，亦未停止 `MicrophoneService` 前台服务；且 `MicrophoneService.onDestroy` 因 `Runtime.audioRequest` 被前置置空导致状态更新条件短路，通知未被移除。
- 双端 Stop 将 TCP 控制套接字关闭，把瞬态音频会话与保活控制通道强耦合；停止后 `pausedByUser` 阻止了后续重连与 `prepare`，造成死锁。

---

## 2. 核心调用链修复与审计整改

### 调用链 A：Mac 端在 Wi-Fi 模式下点击“开始拾音”
- **原代码缺陷**：`macos/Core/SessionController.swift:513` 无论传输方式直接进入 `startAudio`，在无 USB 设备时创建未握手的 `OwnedSession`，在手机后续发来 `prepare` 时以 `MAC_BUSY` 互斥拒绝。
- **修复与落地**：
  - 在 `SessionController.swift` 中针对 Wi-Fi 传输拦截分流至 `startWifiMicrophone(source:)`；
  - 若已存在已认证的手机控制通道，调用 `wifiService.requestStart()` 发送全新已签名服务端命令 `event-start`；
  - 若手机尚未连入局域网，Mac 明确将麦克风状态标记为 `connecting`（“等待已绑定手机连接”），绝不提前创建未确认的 `OwnedSession`，避免 `MAC_BUSY` 锁死；
  - 在 `startAudio` 中彻底剔除旧的 Wi-Fi ADB shell 调用分支。

### 调用链 B：Mac 端在 Wi-Fi 模式下点击“停止拾音”
- **原代码缺陷**：Mac 发送 `event-stop` 后，Android 端未调用 `Runtime.stop(context, req)` 停止服务；且 `MicrophoneService.onDestroy` 无法正确重置状态机。
- **修复与落地**：
  - 在 `WifiAutoConnector.kt` 中封装统一的 `stopAudioService(expectedSessionID, reason)`：显式调用 `Runtime.stop(context, req, source = reason)`，确保向系统发送明确的 `stopService` Intent；
  - 在 `MicrophoneService.kt:onDestroy` 中增加显式 `stopForeground(STOP_FOREGROUND_REMOVE)`，保证通知栏图标立即移除；
  - 在 `Runtime.kt:onMicrophoneServiceStopped` 中由匹配当前会话的停止回调重置麦克风模块状态为就绪。

### 调用链 C：控制长连接与音频会话分离模型
- **架构确立**：
  - 用户停止拾音仅表示终止当前音频推流，不等于断开设备间双向可信控制通道；
  - 手机端或 Mac 端停止时，仅拆除音频接收/采集管线，**保持 TCP 控制套接字与心跳保活循环继续运行**；
  - 停止后状态机保持在暂停状态（`pausedByUser = true`），心跳持续维护，绝不自动唤醒录音。

### 调用链 D：停止后在任意一侧再次点击“开始拾音”
- **Mac 侧再次点击开始**：`startWifiMicrophone` 将本地 `pausedByUser` 置为 `false`，通过长连接发送 `event-start`；手机端收到后清空 `pausedByUser` 并以 `userInitiated=1` 发起 `prepare`；
- **手机侧再次点击开始**：`onUserStartedExplicitly` 直接通过活跃长连接发送 `prepare(userInitiated=1)`；Mac 端 `WifiControlService` 解析到 `userInitiated == true` 时自动重置 `pausedByUser = false` 并放行；
- `SessionController.wifiPrepare` 检查若有残留正在停止的任务（`stopping.contains(.microphone)`），主动等待其完成，杜绝竞争拒绝。

---

## 3. 阻塞性缺陷 (Blockers) 专项整改

### 3.1 阻塞点 A：陈旧服务回调与作用域隔离 (Stale Callback & Scope Isolation)
- **风险分析**：如果录音 A 结束过程缓慢，在此期间启动了新录音 B（或 USB 录音），录音 A 的延迟回调（如 `onDestroy`）若无会话校验，会直接把录音 B 的 `isStreaming` 置为 false 并发送停止指令，甚至杀掉无关的 USB 会话。
- **修复整改**：
  1. `WifiAutoConnector.onMicrophoneServiceStopped(session: String?, ...)` 恢复严格的会话匹配校验：仅当 `session != null && curr.sessionID == session` 时才处理状态变更并发送 stop；若不匹配，坚决不触碰 `currentSession`。
  2. `stopAudioService(expectedSessionID: String? = null, ...)` 增加模式与会话边界检查：仅当 `req.mode == "wifi"` 且在提供 `expectedSessionID` 时要求 `req.session == expectedSessionID`，严禁关闭 USB 录音或更新的 Wi-Fi 录音。
  3. `closeSessionIfOwner` 与 `closeCurrentSessionExplicitly` 均捕获当前 session 的 `sessionID` 并精确传入 `stopAudioService`。
  4. `MainActivity.startAccepted` 检查陈旧请求替换时限制 `existingAudio.mode == request.mode`。

### 3.2 阻塞点 B：停止后迟到 `prepared` 响应与音频意图保护 (Audio Intent / Epoch & Late Prepared Race)
- **风险分析**：由于控制通道保持打开，若在 `prepare` 发出后用户立即点击“停止拾音”，随后网络收到了来自 Mac 的 `prepared` 响应；若缺乏序列号校验与取消意图检查，该迟到的 `prepared` 会意外重新拉起录音服务，违背用户的停止意图。
- **修复整改**：
  1. 在 `ActiveSession` 中引入 `@Volatile var pendingPrepareSeq: Int = -1` 与 `@Volatile var audioEpoch: Long = 0L`。
  2. 每次发出 `prepare` 时记录 `pendingPrepareSeq = seq` 并自增 `audioEpoch`。
  3. 用户主动 Stop、收到 `event-stop` 或出错时，立即自增 `audioEpoch` 并将 `pendingPrepareSeq` 置为 -1。
  4. 收到 `prepared` 时：
     - 校验 `ack == session.pendingPrepareSeq && session.pendingPrepareSeq != -1`，不匹配则丢弃并记录 `badAck`；
     - 校验 `if (pausedByUser)`：若用户在等待期间已点击停止，立即向 Mac 回发已签名 `stop(reason = "cancelledPaused")`，释放 Mac 端的 `autoGrant`，绝不启动录音；
     - 严格校验音频参数（`prepRate`, `prepChannels`, `prepFormat`, `prepSource`）是否与当前请求一致，不匹配则回发 `stop(reason = "unsupportedParams")` 并取消；
     - 在 `postOnMain` 交付执行边界捕获当时的 `audioEpoch`，再次校验 `!pausedByUser && session.audioEpoch == capturedEpoch`，若失效则回发 `stop(reason = "cancelledStale")`。

### 3.3 阻塞点 C：暂停状态下断线重连恢复 (Control Reconnect under Paused State)
- **风险分析**：当用户暂停音频后，若因 Wi-Fi 波动导致底层 TCP 控制连接断开，原代码因 `pausedByUser` 判定短路，彻底阻止了重连探测。结果导致控制连接一旦断开就无法自愈，Mac 端点击开始时再也找不到手机控制通道。
- **修复整改**：
  1. 明确解耦“音频暂停”与“控制通道保活”：控制通道始终保持探测与重连；
  2. 在 `checkAutoConnect` 中移除 `if (pausedByUser && !userInitiated) return`，允许建立控制连接；
  3. 在 `connectAndPrepare` 中，建连认证完成后判断 `if (!pausedByUser)`：若处于暂停状态，**仅保持在空闲已认证控制循环，绝不自动发起 prepare**；
  4. 在 `closeSessionIfOwner` 与重连退避调度中，断线后无条件调度 `scheduleReconnect()`，确保控制连接迅速自愈。

### 3.4 回归防护 D：Mac 侧停止路径早期返回限定 (Mac Stop Cleanup & USB Preservation)
- **风险分析**：原代码在 Mac 侧 `stop(.microphone)` 中增加了 `if owned[module] == nil { return }`。这破坏了 USB 传输的取消逻辑（USB 在启动过程中 `owned[module]` 为空但有 `jobs[module]` 正在运行），也会泄漏正在准备中的 `autoGrant`。
- **修复整改**：
  1. 将早期返回严格限制在 Wi-Fi 模式且确认无任何麦克风工作的前提下：
     ```swift
     if snapshot.settings.transport == .wifi,
        owned[module] == nil,
        jobs[module] == nil,
        autoGrant == nil,
        !stopping.contains(module) {
         status(.microphone, .stopped, "已停止拾音", "已暂停等待手机连接")
         refreshWifiSnapshot()
         return
     }
     ```
  2. 在 Mac `stop(_ module: Workspace)` 执行体中增加对 `autoGrant` 的显式清理与通知；
  3. 在 `wifiEnd` 中同时支持匹配 `autoGrant?.sessionID == sessionID || owned[.microphone]?.id == sessionID`，确保无论处于握手还是传输期，均可被手机端 stop 清理。

---

## 4. 控制通道与音频传输解耦架构

```
+--------------------------------------------------------------------------------+
|                        持久保活控制层 (Control Plane)                          |
|   (基于 TCP 传输，采用 P-256 ECDH 协商密钥与 HMAC-SHA256 逐消息鉴权，无 TLS)  |
|                                                                                |
|   Mac (WifiControlListener)  <===================>  Android (WifiAutoConnector)|
|      - event-start (Mac 发起启动)                    - prepare (手机发起协商)   |
|      - event-stop  (Mac 发起停止)                    - stop    (手机发起停止)   |
|      - state/error (状态与拒绝)                      - status  (5秒签名心跳)    |
|                                                                                |
|   * 在空闲已认证、正在采音、手动暂停等全生命周期内保持长连接保活与掉线自愈。    |
+--------------------------------------------------------------------------------+
                                       |
                     动态触发 prepare / prepared 协商
                                       v
+--------------------------------------------------------------------------------+
|                        瞬态音频传输层 (Audio Plane)                            |
|          (基于 TCP 传输，端口为配置端口 settings.audioPort，在 prepared 中下发)       |
|                                                                                |
|   Mac (AudioReceiver)        <-------------------   Android (MicrophoneService)|
|      - 监听 settings.audioPort 端口                   - AudioRecord 采音        |
|      - AudioToken 首行校验握手                        - 长度前缀原始 PCM 载荷   |
|                                                                                |
|   * 仅在显式开始后分配管线；在停止后立即完全拆除释放。                          |
+--------------------------------------------------------------------------------+
```

---

## 5. 前端界面轻量可用性对齐 (Frontend Usability)

在不改动现有排版、导航结构或设计规范的前提下，核对并微调双端可用性表现：
1. **未配对引导优化**：
   - 在 `LinkMicScreen.kt` 中，当处于自动连接模式且未绑定任何 Mac 时，底部引导由原先误导用户输入 IP 地址改为：“未绑定 Mac：请在下方局域网列表中选择 Mac，核对 6 位验证码完成绑定”。
   - 保留 `4d5df9f` 修复的卡片布局（发现项信息置于配对按钮上方，已绑定列表删除按钮采用内容自适应宽度）。
2. **Wi-Fi 模式设备名与状态展示**：
   - `MicrophoneWorkspaceView.swift`、`MenuBarConsoleView.swift` 与 `RootView.swift` 在 Wi-Fi 模式下优先使用已连接手机名或已信任手机名，彻底解决拔掉 USB 后死锁展示“等待手机连接”的问题。
3. **按钮可用性与双向对齐**：
   - 保证两端“开始拾音”与“停止拾音”直接调度至 Wi-Fi 会话控制通道，不再依赖 ADB。

---

## 6. 详细修改文件与代码证据

| 文件 | 变更位置 | 审计证据与说明 |
| :--- | :--- | :--- |
| `macos/Core/SessionController.swift` | L283-295, L1374-1385, L1670-1696, L1758 | 严格限定 Stop 早期返回条件；在 `stop()` 中显式清理与通知 `autoGrant`；`wifiEnd` 兼容握手与活跃会话清理；剥离 Wi-Fi 下对 ADB 的依赖。 |
| `macos/Support/WifiControlService.swift` | L100, L197, L355, L371, L425-443 | 暴露连接状态；实现 `requestStart`；解析 `userInitiated` 重置暂停；`stop` 响应安全释放并不向客户端发送致命错误。 |
| `macos/UI/MicrophoneWorkspaceView.swift` | L113-126 | Wi-Fi 模式下设备名优先展示已连接/已信任手机名。 |
| `macos/UI/MenuBarConsoleView.swift` | L58-71 | 菜单栏设备名在 Wi-Fi 模式下准确展示手机名。 |
| `macos/UI/RootView.swift` | L330-340 | 侧边栏底部设备摘要增加 Wi-Fi 状态展示。 |
| `android/.../WifiAutoConnector.kt` | L201, L214, L302, L335, L360, L625, L740-880, L900-940 | 引入 `pendingPrepareSeq` 与 `audioEpoch`；严格隔离 `onMicrophoneServiceStopped` 作用域；`stopAudioService` 增加模式与会话边界；解除暂停对控制长连接重连的阻碍；安全处理迟到 `prepared` 与拒绝取消。 |
| `android/.../MicrophoneService.kt` | L680, L694 | `onDestroy` 增加显式 `stopForeground(STOP_FOREGROUND_REMOVE)`；仅当 `Runtime.audioRequest === currentRequest` 时清理全局引用。 |
| `android/.../MainActivity.kt` | L156-166 | `startAccepted` 检查陈旧请求替换时限制 `existingAudio.mode == request.mode`。 |
| `android/.../Runtime.kt` | L380-388 | `onMicrophoneServiceStopped` 会话匹配时负责将状态机重置为就绪。 |
| `android/.../ui/LinkMicScreen.kt` | L473-483 | 首次未绑定状态下文案引导用户在下方选择 Mac 完成 6 位码确认，避免误导输入 IP。 |
| `contracts/wifi-auto-connect-v1.md` | L179, L187-193 | 补充 `event-start` 规范与控制通道/音频传输解耦说明。 |

---

## 7. 潜在边界、客观物理限制与非回归说明

1. **Android 后台采音系统限制 (Physical/OS boundary)**：
   - 根据 Android 14+ / targetSdk 34+ 规范，应用在后台/无前台 Activity 时禁止拉起麦克风前台服务（`ForegroundServiceStartNotAllowedException`）。
   - 本修复在 Android App 处于前台或处于合法可启动窗口期内工作正常；若手机屏幕长久熄灭、App 被系统彻底杀掉或被后台冻结，Mac 单向发送 `event-start` 无法突破 Android 系统的安全防线。用户需确保手机端 App 处于前台或在前台状态下开启连接。
2. **Wi-Fi 网络拓扑限制 (Network boundary)**：
   - 依赖局域网双向组播/TCP 通信。若路由器开启了 AP 隔离（访客网络），Bonjour 广播和 TCP 连接无法建立，此属网络物理隔离，代码无法绕过。
3. **USB 链路无回归审计说明 (Static Deduction, Not Device Acceptance)**：
   - 经过对 `SessionController.swift`、`MainActivity.kt` 和 `Runtime.kt` 的审查：
     - USB 采音分流在 `SessionController` 中始终调度至 `startAudio`，未被 Wi-Fi 分流截断；
     - `SessionController.swift:283` 的早期返回已被严格限制在 Wi-Fi 模式，USB 停止调用始终正常进入 `stop(module)` 执行 ADB/守护进程清理；
     - `Runtime.stop` 与 `stopAudioService` 均强制检查 `req.mode == "wifi"`，确保 Wi-Fi 侧动作无法误伤 USB 采音；
     - 以上结论来自静态代码隔离推导，由于本阶段不执行设备自动化测试，最终非回归仍需结合真机验收确认。

---

## 8. 实际执行与跳过的检查

- **实际执行的离线类型检查**：
  1. `swift build`：**通过**（exit code 0，耗时 5.22s，无错误）。
  2. `swift build --build-tests`：**通过**（exit code 0，耗时 2.70s，全部测试目标编译无错误）。
  3. `./android/gradlew -p android :app:compileDebugKotlin --console=plain`：**通过**（exit code 0，`BUILD SUCCESSFUL in 11s`，15 actionable tasks）。
- **按明确约束跳过的检查**：
  - 未运行任何测试套件（Mac 隔离测试、Android 单元测试均按用户要求未执行）。
  - 未执行 ADB 指令、真机交互、应用安装、模拟器或抓包调试。
  - 未启动任何脱离进程组的守护服务。
  - 未执行 `git push`。

---

## 9. 终审六项不变量静态调用链推演 (Final Six Invariants Static Walk Audit)

### 9.1 时序 1：会话 A 停止后，迟到的 `stopped` ACK 绝不误杀新会话 B (Late Stopped ACK Correlation)
- **风险模型**：手机发起 Stop(A) (`pendingStops[seqA] = A`)，随后快速发起 Start(B) 并准备就绪 (`session.sessionID = B`)。随后 Mac 端针对 seqA 的 `{"cmd":"stopped", "ack":seqA, "session":A}` 到达。
- **静态代码链与防护**：
  - `WifiAutoConnector.kt:948` 收到 `stopped`：从 `pendingStops` 移除 `ack`，解析得到 `stoppedSession = A`。
  - 执行强校验：`if (stoppedSession.isNotBlank() && session.sessionID == stoppedSession)`。
  - 此时 `session.sessionID == B != A`，条件为 false。
  - 执行 `Runtime.log("wifi", "staleStoppedAckIgnored", ...)` 并安全忽略。
  - 绝不调用 `stopAudioService`，不清除 `session.sessionID`，不自增 `audioEpoch`，不打断 B 的 `pendingPrepareSeq`，TCP 控制通道保持正常运行。

### 9.2 时序 2：空闲控制通道关闭绝不触发通配符全局音频拆除 (No Wildcard stopAudioService)
- **风险模型**：手机端旧的控制长连接发生超时断开，或控制通道处于空闲未采音状态（`capturedSessionID == ""`）。
- **静态代码链与防护**：
  - `WifiAutoConnector.kt:1038` 执行 `closeSessionIfOwner`，传入 `capturedSessionID = ""`。
  - `WifiAutoConnector.kt:306` `stopAudioService(expectedSessionID)` 入口第 1 行严格执行 `if (expectedSessionID.isBlank()) return`。
  - 空 ID 立即拦截返回，绝不接触全局 `Runtime.audioRequest`，绝不向系统发送 `Runtime.stop(context, req)`。
  - 哪怕此时已由 USB 模式或全新 Wi-Fi 会话建立了录音，均获得绝对所有权隔离，不受空闲控制连接释放影响。

### 9.3 时序 3：Prepare 发起后被用户取消，迟到 `prepared` 优雅回收且不破坏通道 (Prepare / Cancel Reordering)
- **风险模型**：手机发出 `prepare(seq = 10)`，用户在握手响应返回前点击“停止拾音” (`onUserStoppedExplicitly`)；随后 Mac 端针对 seq=10 的 `prepared(ack = 10, session = grantA)` 到达。
- **静态代码链与防护**：
  - 用户点击停止：`active.cancelledPrepareSeqs.add(10)`，`active.pendingPrepareSeq = -1`，`audioEpoch++`。
  - Mac 响应到达：`WifiAutoConnector.kt:786` 首先进行 HMAC-SHA256 逐包鉴权，校验通过。
  - 进入判断 `ack == session.pendingPrepareSeq` (false，此时为 -1)。
  - 进入 `else if (session.cancelledPrepareSeqs.remove(ack))` (true，10 被移除并命中)。
  - `session.expectedServerSeq++`，记录日志 `stalePreparedCancelled`。
  - 在后台守护线程发出 `sendAuthenticatedStop(session, reason = "cancelledStalePrepare", sessionIDOverride = grantA)`，通知 Mac 释放已分配的 `grantA`。
  - **不退出 `runSessionLoop`（不 break），不抛出异常，不修改当前已清空或属于新会话的 `sessionID`**，TCP 长连接保持活跃。

### 9.4 时序 4：对端所有权安全防线，Peer B 绝不篡改/终止 Peer A 的授权 (Peer Ownership Security)
- **风险模型**：Peer A 处于活跃采音或 prepare 准备状态，Peer B（拥有合法的单独局域网认证密钥）连接至 Mac 并发送 `{"cmd":"stop", "session":grantA}`。
- **静态代码链与防护**：
  - `macos/Support/WifiControlService.swift:440` 处理 `stop` 指令。
  - 检查 `if let current = active, current.id == session`：
  - 执行所有权核对：`guard current.phoneID == conn.phoneID else { return push(conn, command: "error", ack: seq, fields: ["code": "FORBIDDEN"], macFields: "FORBIDDEN") }`。
  - 此时 `current.phoneID (A) != conn.phoneID (B)`，直接向 Peer B 回送已签名的 `FORBIDDEN` 错误响应，阻断执行，绝不调用 `host?.wifiEnd`。
  - 在后备路径中，`wifiEnd` 传递 `phoneID: conn.phoneID`；`macos/Core/SessionController.swift:1760` 收到后同样校验 `if let phoneID = phoneID, let grant = autoGrant, grant.sessionID == sessionID, grant.phoneID != phoneID { return }`，两层防御彻底杜绝越权停止。

### 9.5 时序 5：未配对引导与按钮可用性状态机闭环 (UI / Action Routing in Auto-Connect)
- **风险模型**：用户开启了“局域网自动连接”，但当前 `trusted` 为空（尚未配对任何 Mac）。
- **静态代码链与防护**：
  - `LinkMicScreen.kt:233`：`canStart = !settingsDirty && (if (snapshot.settings.wifiAutoConnect) hasTrustedMac else snapshot.settings.wifiHost.isNotBlank())`。
  - 由于 `hasTrustedMac` 为 false，`canStart` 严格计算为 `false`。
  - 界面“开始拾音”按钮呈现禁用状态，下方清晰提示：“未绑定 Mac：请在下方局域网列表中选择 Mac，核对 6 位验证码完成绑定”。
  - 若通过快捷动作调用 `UserAction.StartWifi`，`MainActivity.kt:175` 拦截：`if (settings.wifiAutoConnect)` 分支直接检查 `trustStore.loadTrustedMacs()`，若为空则在界面上显示 `尚未绑定 Mac，请在下方已发现设备中点击配对` 并直接 `return`，绝不回退至旧的 `settings.wifiHost` 手动连接。

### 9.6 时序 6：Mac 端在 `wifiEnd` 中彻底取消排队与在途音频任务 (Mac Pending Cancellation in wifiEnd)
- **风险模型**：手机端发起 `wifiEnd`，此时 Mac 端可能处于 `wifiPrepare` 刚刚批准 `autoGrant`、正在启动 AudioReceiver 的临界状态，`owned[.microphone]` 尚为空但 `jobs[.microphone]` 正在运行。
- **静态代码链与防护**：
  - `SessionController.swift:1765` 收到 `wifiEnd`，调用 `await stop(.microphone, source: .phone)`。
  - `SessionController.swift:1378` 立即执行 `jobs[.microphone]?.cancel()`，取消在途启动协程。
  - 若 `autoGrant` 匹配，清理 `autoGrant = nil` 并通知 `wifiService`。
  - 当 `owned[.microphone] == nil` 命中时：执行 `receiver.stop(); output.stop(); audioDelivery = nil`，清理底层音频资源，并更新状态为 `.stopped`，杜绝任何孤儿音频监听套接字残留。


## 10. 主代理交接复核

- 复核代码提交：`e439e7a`。已逐项检查迟到停止回执的会话 ID 比较、空 ID 拆除拒绝、已取消 prepare 的迟到回复处理、手机身份向接收端透传、未绑定时阻止手填地址回退，以及 Mac 在途任务取消。
- 前端差异限定为现有设备名称、状态提示和按钮可用条件；保留既有布局及发现卡片修复。
- 已核对 AGY 原始命令记录中的 Swift 应用/测试目标编译及 Android Kotlin 编译成功输出。测试目标仅编译，未执行测试用例；本轮未使用 ADB、运行设备测试或安装应用。
- `ack` 本身仍不在既有 HMAC 输入中；停止回执的处理还依赖已签名会话 ID 与当前会话比较，不能把 `pendingStops` 记录描述为完整的密码学请求绑定。该限制与协议文档一致。
- 本轮增加 `event-start` 并调整停止后的控制通道生命周期，需要两端成套构建更新。之前的 Review-4 安装包不包含这些提交；本轮仅交付源码和审计记录。
- 待用户验证：拔掉 USB 后首次绑定与自动采音；Mac 停止/手机开始、手机停止/Mac 开始；停止后持续暂停；准备过程中停止并快速重启；断网后恢复控制与音频；实际 BlackHole 输入。
