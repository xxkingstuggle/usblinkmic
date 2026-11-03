# USBLinkMic Wi-Fi 自动连接协议规范 (v1)

## 1. 协议概述与定位
Wi-Fi 自动连接协议专为局域网（同 Wi-Fi 或 Android 热点加入）下的 Mac 与 Android 设备提供零配置、免输入 IP/端口、无须 ADB/USB 的高保真麦克风拾音能力。
协议核心设计目标：
1. **免手动配对输入**：初次发现后只需单侧安全确认（手机端呈现 6 位验证码，Mac 端弹出授权提示并核对一致后点击“允许并绑定”）；之后永久互信绑定。
2. **断网与变网自愈**：支持 Wi-Fi 漫游、热点重连、IP 变化及单侧静默断开的重连（1s..15s 指数退避，无固定 5 次熔断上限）。
3. **严格防伪造与防重放**：所有控制信令均基于预共享密钥 / 配对密钥计算 HMAC-SHA256 消息认证码（MAC），校验序列号（seq）与确认号（ack）。
4. **单活跃所有权与代际隔离**：使用单调递增的代际计数器（generation）和单活跃会话机制，杜绝并发竞争、僵尸线程与晚到回调污染。
5. **明确的手动停止语义**：用户手动停止（Mac 界面点停止或手机点停止）置位 `pausedByUser`，暂停自动发现与重连，不被任何自动任务覆盖，直到用户主动触发开始。

---

## 2. 局域网服务发现 (Bonjour DNS-SD)

### 2.1 服务发布与检索
- **服务类型**：`_usblinkmic._tcp.`
- **传输层**：TCP 动态监听端口（控制通道）。
- **注册域**：`local.`
- **Mac 端广播**：Mac 启动 Wi-Fi 监听器后发布 Bonjour 服务，服务名称格式为 `USBLinkMic-<macID[:8]>`。
- **Android 端检索**：使用 `NsdManager` 持续发现 `_usblinkmic._tcp.`，支持热点模式及普通局域网。

### 2.2 TXT 记录属性 (TXT Record Attributes)
| 属性键 | 类型 | 说明 |
| :--- | :--- | :--- |
| `id` | String | Mac 设备唯一 ID（32 字符 Hex），持久化于 `wifi-trust.json`。 |
| `name` | String | Mac 设备可读名称（截断至前 40 字符）。 |
| `v` | String (Int) | 核心协议版本，当前固定为 `"4"`。 |
| `w` | String (Int) | Wi-Fi 协议修订版本，当前固定为 `"1"`。 |
| `rev` | String (Int) | 运行时版本基线，当前固定为 `"416"`。低于基线直接拒绝握手。 |

---

## 3. 控制通道报文传输 (Framing & Wire Format)

- **传输层**：面向连接的 TCP 串行流。
- **编码格式**：UTF-8 编码的单行 JSON，以换行符 `\n`（LF）作为报文定界符。
- **单行最大长度**：Mac 与 Android 限制单行最大 4096 字节（超长立即切断连接）。

---

## 4. 握手与能力协商 (Hello Handshake)

连接建立后，首个交互报文必须由客户端（Android）发起 `hello` 握手。

### 4.1 客户端请求 (`cmd: "hello"`)
```json
{
  "cmd": "hello",
  "protocol": 4,
  "wifi": 1,
  "runtimeRevision": 416,
  "phoneID": "79b48c...",
  "phoneName": "Pixel 7 Pro",
  "nonce": "a1b2c3d4e5f6...",
  "macID": "9f8e7d..."
}
```
- `phoneID`：32 字符 Hex，手机端持久化唯一标识。
- `nonce`：客户端生成的 16 字节随机 Hex（防重放与会话密钥派生）。
- `macID`：手机期望连接的 Mac 标识（用于防误联及服务漂移校验）。

### 4.2 服务端响应
- **成功**：
  ```json
  {
    "ok": true,
    "nonce": "1234567890abcdef...",
    "macID": "9f8e7d..."
  }
  ```
- **失败**：
  ```json
  {
    "ok": false,
    "error": "INCOMPATIBLE_RUNTIME" | "BAD_PROTOCOL" | "WRONG_MAC"
  }
  ```

---

## 5. 首次配对流 (Pairing Flow)

若 Mac 端尚未信任该 `phoneID`，进入配对流程。

### 5.1 密钥交换 (ECDH P-256)
1. 客户端生成临时密钥对（NIST P-256 / secp256r1）。
2. 发送公钥（X9.63 未压缩 65 字节 Base64 编码）：
   ```json
   {
     "cmd": "pair",
     "pub": "BC1d4..."
   }
   ```
3. 服务端生成自己的临时 ECDH 密钥对，派生共享密钥：
   `sharedSecret = ECDH(ServerPriv, ClientPub)`
   `pairingKey = HMAC-SHA256(sharedSecret, "usblinkmic-wifi-pair-v1|" + macID + "|" + phoneID + "|" + clientNonce + "|" + serverNonce + "|" + phonePub + "|" + macPub)`
4. 服务端返回自己的公钥与 `requestID`：
   ```json
   {
     "ok": true,
     "macPub": "BD5e2...",
     "requestID": "req-987654..."
   }
   ```

### 5.2 6 位验证码 (SAS Verification Code)
- 两端独立通过 `pairingKey` 派生 6 位数字：
  `digest = HMAC-SHA256(pairingKey, "sas")`
  `code = ((digest[0]<<24) | (digest[1]<<16) | (digest[2]<<8) | digest[3]) % 1000000`
- 手机端界面展示验证码。
- Mac 弹出授权弹窗，展示待配对设备名称与 6 位数字，用户核对后点击“允许并绑定”进行授权。

### 5.3 配对状态轮询与证明
客户端每隔 1s 发送：
```json
{
  "cmd": "pairStatus",
  "requestID": "req-987654..."
}
```
Mac 用户点击“允许并绑定”后，服务端返回批准证明：
```json
{
  "ok": true,
  "status": "approved",
  "proof": "fd41055d..."
}
```
其中 `proof = HMAC-SHA256(pairingKey, "pair-approved|" + requestID + "|" + macID + "|" + phoneID)`。
客户端验证 `proof` 一致后，将 `pairingKey`（作为持久化身份共享密钥）存入本地信任库，完成配对。

---

## 6. 相互认证 (Mutual Authentication)

已信任设备在 `hello` 成功后直接执行相互认证。

### 6.1 客户端证明 (`cmd: "auth"`)
```json
{
  "cmd": "auth",
  "phoneID": "79b48c...",
  "proof": "0fb13714..."
}
```
- `clientProof = HMAC-SHA256(psk, "auth-c|" + macID + "|" + phoneID + "|" + clientNonce + "|" + serverNonce)`

### 6.2 服务端响应
- **成功**：
  ```json
  {
    "ok": true,
    "proof": "480533b3..."
  }
  ```
  - `serverProof = HMAC-SHA256(psk, "auth-s|" + macID + "|" + phoneID + "|" + clientNonce + "|" + serverNonce)`
- **失败**：服务端返回 `ok: false, error: "AUTH_FAILED"`。Mac 端维护 60 秒滑动窗口，若同一 `phoneID` 在 60 秒内累计认证失败达 5 次，后续连接立即被速率限制并返回 `{"ok": false, "error": "RATE_LIMITED"}`。

---

## 7. 认证后信令与 MAC 规范 (Authenticated Messaging)

认证成功后，所有后续双向报文必须包含序列号 `seq`、确认号 `ack`（响应方提供）和基于本次握手随机数计算的 `mac`：

$$MAC = \text{HMAC-SHA256}(psk, \text{"msg|" + direction + "|" + clientNonce + "|" + serverNonce + "|" + seq + "|" + cmd + "|" + fields})$$
- `direction`：客户端发往服务端为 `"c"`，服务端发往客户端为 `"s"`。
- `fields`：各命令对应的特定规范化字段串联（用 `|` 分隔）。

### 7.1 命令字典

| 命令 (`cmd`) | 方向 | 说明 | `fields` 规则 |
| :--- | :--- | :--- | :--- |
| `prepare` | C $\to$ S | 手机请求 Mac 分配音频接收端口与会话 ID | `sampleRate\|channels\|format\|source\|userInitiated(1或0)` |
| `prepared` | S $\to$ C | Mac 成功绑定音频接收端口返回会话信息 | `session\|audioPort\|sampleRate\|channels\|format\|source` |
| `status` | C $\to$ S | 客户端心跳请求（每 5 秒） | 空字符串 `""` |
| `state` | S $\to$ C | 服务端会话状态响应（响应心跳或状态变迁） | `session\|state`（state 取值 `streaming` / `preparing` / `ended`） |
| `stop` | C $\to$ S | 客户端请求停止音频会话 | `session\|reason`（如 `userStopped` / `phoneStop`） |
| `stopped` | S $\to$ C | 服务端确认已停止音频会话 | `session` |
| `event-stop`| S $\to$ C | 服务端主动通知客户端会话已终止 | `session\|reason`（如 `macUser` / `audioFailed` / `macQuit`） |
| `error` | 双向 | 业务拒绝或错误 | 错误码字符串（如 `PAUSED_BY_USER` / `UNAVAILABLE`） |

### 7.2 音频会话令牌与传输格式 (Audio Transport)
在 `prepared` 返回后，两端派生用于音频连接首行握手的音频令牌：
$$\text{AudioToken} = \text{HMAC-SHA256}(psk, \text{"audio|" + sessionID + "|" + clientNonce + "|" + serverNonce})$$
音频传输使用独立 TCP 连接至 `audioPort`。连接建立后，客户端首行发送单行 JSON 握手报文：
```json
{
  "protocol": 4,
  "session": "<sessionID>",
  "token": "<audioToken>",
  "sampleRate": 44100,
  "channels": 1,
  "format": "i16",
  "source": "microphone"
}
```
握手成功后，后续音频数据以“长度前缀原始 PCM 帧”（4 字节大端整数长度 + 原始 PCM 载荷）连续串流传输，帧内部不附加逐帧 token、MAC 或加密开销；服务端一旦读取到非法长度或断开即切断会话。

---

## 8. 状态机、生命周期与重连管理

### 8.1 客户端连接状态相位 (`WifiAutoPhase`)
1. `OFF`：用户在设置中关闭了 Wi-Fi 自动连接。
2. `SEARCHING`：正在局域网检索 Mac 广播。若无已信任 Mac，提示配对；若有已信任 Mac，提示正在等待连入。
3. `CONNECTING`：发现目标 Mac，正在进行 TCP 连接、Hello 协商与 Auth 相互认证。
4. `PREPARING`：已完成认证与 prepare，音频监听器已就绪，正在启动本地麦克风服务。
5. `STREAMING`：音频采集已开始，且已收到双向状态确认或音频帧，处于稳定拾音串流阶段。
6. `PAUSED`：用户主动点停止，自动重连挂起。
7. `FAILED`：配对或连接遭遇不可恢复的错误。

### 8.2 超时与保活预算
- **建连/前认证超时**：8 秒未收到合法响应，断开连接重置。
- **控制通道心跳周期**：客户端每 5 秒发送一次 signed `status`。
- **响应超时预算 (Deadline Budget)**：客户端在发出心跳后，如果在预定时间内（默认 10 秒）未收到任何来自服务端的合法已签名响应（如 `state` / `stopped` 等），判定连接进入黑洞状态，主动断开并触发自愈重连。
- **服务端空闲断开**：控制通道连续 20 秒无有效数据活动，强制切断。
- **音频孤儿会话宽限期 (Orphan Grace)**：若控制通道异常中断，Mac 音频监听器保持 15 秒宽限期以容忍快速重连。超过 15 秒仍无重连则释放音频资源。

### 8.3 重连退避策略 (Exponential Backoff)
- 初始重连间隔：1 秒。
- 遇网络或服务暂时异常：每次退避倍增（1s $\to$ 2s $\to$ 4s $\to$ 8s $\to$ 15s），上限 15 秒。
- **无固定尝试次数熔断**：局域网设备常因 Mac 休眠或网络切换而暂时断开，客户端必须持续以 15 秒退避探测，Mac 唤醒后能立即恢复。
- 用户主动干预（点击“开始拾音”或切换 Wi-Fi 开关）立即重置退避计时器为 1 秒。

### 8.4 界面生命周期解耦
- Android 端 `MainActivity.onStop()` 仅暂停后台 NSD 检索以节省电量，绝不终止进行中的控制连接与录音前台服务。
- 只有用户点击“停止拾音”或控制通道收到 `event-stop` / 错误时，前台麦克风服务才会被安全退出。
- 手机端屏幕旋转或 Activity 重建不触发重新建连。
