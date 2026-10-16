# Frozen contract v1 / wire protocol 4
Canonical parameter sets and default values: macos/Contracts/Models.swift and android/.../contracts/Models.kt. Changes belong to main executor only. UI consumes snapshots and emits UserAction; never fabricates device/audio/network state.

## State and ownership
Each start owns a UUID, immutable selected serial and cancellation generation. Repeated start while active is idempotent. Stop invalidates generation before closing owned socket/process/ADB mapping. All asynchronous completions check generation; retries are explicit after failure. Direction switching stops and restores the other network task first. No broad adb forward --remove-all, kill-server, network reset, or uninstall.
Permissions have separate notRequested/waiting/allowed/denied/settingsRequired values; notification denial does not deny recording. Waiting user has no first-frame deadline. First-frame deadline starts after RECORDING ack. Audio streaming requires valid frames (all-zero PCM counts); running network requires actual bound/protected HTTP probe, not tunnel presence. Exit cleanup bounded to 5s, journal owned resources for next launch, never restart recording on launch.

## Wire
USB: Mac binds audio listener loopback and `adb -s SERIAL reverse tcp:48124 tcp:48124`; Android activity started with session + settings + one-time 128-bit pairing token. ADB control via forwarded TCP 48125, read-only status and authenticated stop only; exported activity requires explicit visible user consent on each new Mac audio/VPN request. Third-party activity launches cannot silently start services. Phone persists no tokens.
Wi-Fi: Mac binds explicitly selected local IPv4, user copies generated session token to phone. Only one accepted sender. First newline JSON (max 8192 bytes): {protocol:4,session,token,sampleRate,channels,format:"i16"|"f32",source}. Server replies one JSON {accepted:true} or error then closes. No mixing/replacement by second sender. Trusted LAN only; token not encryption.
Audio frames: unsigned 32-bit big-endian length then interleaved little-endian PCM, frame aligned, 1..262144 bytes. Frame counter and level derive only from decoded samples. Sender uses requested exact AudioRecord format; unsupported configuration fails, no fallback. Broken frame/stream is explicit failure.
Control status newline JSON: protocol, session, recording, microphonePermission, notificationPermission, vpnPermission, error, effective audio. Auth via session token. Replies max 8192 bytes. Control session remains alive while waiting permission; stopping sends authenticated cancel and closes resources.
Network reverse tunnel will use a pinned official transport dependency (Apache-2.0) if justified; phone companion owns VPN permission, foreground service, DNS/routes and actual probe. NCM via ADB shell capability check and explicit system tethering control; unsupported denied commands stay unsupported, no root workaround. Own only changed USB function; journal old value before mutation, restore after stop/failure.

## Support module API (frozen)
Swift `public enum SettingsValidator { public static func errors(_ settings: Settings) -> [String] }`; `public final class SettingsStore { public init(url: URL); public func load() throws -> Settings; public func save(_ settings: Settings) throws }`; `public enum LogRedactor { public static func redact(_ text: String) -> String }`. Imports Contracts. Validate finite gain 0...4, ranges from Capabilities, IPv4 DNS, IPv4 CIDR routes, valid listener IPv4, distinct ports 1024...65535, optional Wi-Fi hostname/IP, pairingCode optional or 32 hex chars. Store atomic, no unrelated UserDefaults.
Kotlin support `object SettingsValidator { fun errors(settings: Settings): List<String> }`; `class SettingsStore(context: android.content.Context) { fun load(): Settings; fun save(settings: Settings) }`; `object LogRedactor { fun redact(text: String): String }`. App-private SharedPreferences, complete serialization, validate before save.
Redact serials in structured `serial=...`, IPv4/IPv6, user-home paths and token=...; don't claim arbitrary text sanitization. Logs ring max 500, export user selected file, no automatic cloud upload.

## UI integration
Swift target module UI: `public struct RootView: View { public init(snapshot: AppSnapshot, send: @escaping (UserAction)->Void) }`. Own five workspaces + wizard/settings draft; no @main, no backend. Import Contracts, optionally Support. Window min 720x520. Real stage/detail/error always shown, no mock data. No integration tests may be replaced by fixtures.
Android composable `@Composable fun LinkMicScreen(snapshot: AppSnapshot, onAction: (UserAction) -> Unit)` package com.zjx.usblinkmic.ui. No Activity, Manifest, permission requests, audio or VPN. Three modules, settings draft validation, logs, Wi-Fi host/token/start/stop. UI never sets running itself.

NCM clarification v1.1: visible companion request mode `ncm` confirms and opens Android system tether settings. `accepted` is explicit user consent, not permission or network success. Mac selects only a unique newly addressed interface with exactly one attached online USB device; ambiguity fails. Authenticated `ncmState` updates phone UI only after Mac interface-bound HTTPS204 probe. No Mac route/service mutation; saved USB functions restored on cleanup and prior exit probe checked. Actual default-route use remains a separate hardware acceptance assertion, not inferred from bound request.
Protocol discovery v1.2: read-only `content://com.zjx.usblinkmic.capabilities` provider returns protocol/capabilities only to Android shell/system/self (DUMP permission plus UID check). Mac uses protocol4 discovery, not display versionCode, to decide compatibility/update; wire handshake independently rechecks identity and exact format. Probe never starts permissions or services. App update uses install -r, without uninstall or downgrade override.
Cancellation clarification v1.3: install subprocess is cancellable; short ADB resource commands return their receipts even after cancellation so freshly-created mappings can be removed precisely. Failed control-stop delivery falls back to visible companion `mode=cancel` with the matching session/token; the companion records an in-memory cancellation tombstone before any late start request and never launches a service for that cancelled pair. No permission is granted. Tests cover owned-process task cancellation.
Crash recovery records relay PID plus executable path and unique JVM session property; recovery inspects exact process identity before signalling it, never terminates a recycled PID. App-owned journal/config directories are0700 and secret-bearing JSON files0600. Failed cleanup retains its journal for explicit recovery; a changed mapping/USB function/process ownership is not overwritten.

## 4.0.1 会话与设置补充
- Mac AppSnapshot 增加 isSavingSettings/settingsMessage，供界面显示真实保存阶段与结果。保存前统一校验虚拟输出，保存中不允许开始会话；资源停止失败则不提交设置。
- 断流/首包期限按会话隔离，使用单调时钟；未确认录音且未收到帧的准备/授权阶段不计时。停止清除帧数与有效参数。旧会话回调不得影响新会话。协议仍为4，设置schema仍为1。
- 脱敏事件仅本地持久化，最大256KiB，0600；不保存音频、配对码或设备标识。

## 4.0.3 实现修订（用户授权对照归档）
- 用户授权查看归档实现；不再宣称本轮严格净室，但旧库保持只读，协议4及设置schema1保留。两端要求runtimeRevision>=403以升级所需运行时修复，不以显示版本替代协议协商。
- 音频使用DefaultOutput/指定HAL输出的拉取回调与预分配浮点SPSC缓冲；网络数据包数量不作为硬件输出容量。空缓存渲染静音；满缓存仍明确失败并带渲染计数。
- NCM用户确认后由ADB shell启动本APK的NcmShellCommand，限定UID2000与本次session，回调25秒、进程30秒、Mac回执45秒。USB切换的非零退出不单独等于ROM不支持，按重连后的实际功能确认。
- journal记录旧USB功能、共享启动意图与精确的临时结果路径；停止需等启动回执或进程消失，再停止共享并恢复USB。仅删除本session的start/stop结果文件；恢复失败保留journal。
- 本次共享切换会先停止既有USB音频，避免其在USB重枚举中误报断流；共享完成后用户可重新开始音频。不会自动重启采音。
- 供网仍需要新USB接口的实际HTTPS成功和默认出口检查；Tethering回调/IP/进程存在都不单独记网络成功。退出恢复对照原默认出口，不把原上游本来无互联网误当恢复失败。
- 按用户最新指示，本轮编译打包，测试/功能验证由用户执行。

## 4.0.4 NCM与日志修订
- 两端runtimeRevision>=404，协议4/schema1及音频参数保持。NcmShellCommand新增只读status结果：action/session/ok/errorCode/callback/tethered（接口名数组）/upstreamPresent（可选布尔或null）/sdk；List/Set回调均可接受。上游标记只作诊断，不代替HTTPS。
- USB状态来源为svc usb getFunctions→sys.usb.state；sys.usb.config仅诊断。NCM启动另有usb0实际跟踪与tethered确认，停止确认退出共享；取消/恢复不把ADB退出码当作USB结果。
- 私有OwnedSession journal增加可选ncmServices[{name,device,wasEnabled}]及ncmUSBChanged；修改精确USB服务前持久化，失败保留归属重试，恢复期间阻止启动新任务。不能修改其他服务或全局路由。
- 日志启动读入历史，导出磁盘有界历史，显式清除同时清盘。NCM阶段事件覆盖USB、共享、Mac服务/DHCP、HTTPS及恢复，统一LogRedactor脱敏。详见docs/ncm-repair-4.0.4.md。
- shutdown异步返回资源是否恢复；App退出等待该结果，取消5秒提前退出。失败保留UI/归属日志供重试，退出期间禁止新任务。

## 4.0.5 Mac直接启动与准确服务选择

4.0.5入口存在后续启动任务复用回归，已定位于docs/diagnosis-4.0.5-20261016.md；当前修复候选为下述4.0.6，不以旧构建证据宣称入口可用。
- 依据用户新决定，移除应用内每次会话确认；accepted表示已接受受保护入口的Mac命令，不表示系统录音/VPN权限已经授予。recording、真实共享及HTTPS/默认出口仍分别确认，权限等待不计首包超时。通知许可不是启动门槛。
- 新控制入口com.zjx.usblinkmic/.AdbControlActivity由DUMP权限保护，MainActivity只消费同进程一次性ticket。能力报告controlComponent，Mac要求runtimeRevision405并校验该组件；两端成套升级，协议4/schema1未改。journal新增可选controlComponent供精确取消，旧记录保留旧入口。
- getFunctions成功空串为none，getprop空串或失败仍未知。服务发现基线包含持久服务，明确安卓优先，离线iPhone不作为新USB候选。歧义与业务验证门槛不变。


## 4.0.6 可靠命令与资源恢复

- 两端runtimeRevision406，版本4.0.6/40006，协议4/schema1不变。受保护控制入口为独立、无历史、无affinity的瞬时任务；Mac以NEW_TASK|MULTIPLE_TASK执行每条命令，入口再以NEW_TASK转交主界面。onCreate/onNewIntent均处理票据，公开launcher仍拒绝原始会话extras。
- 取消请求附带原controlPort；尚未登记的会话保存取消墓碑并提供鉴权取消状态。Mac在stop命令或后备Activity启动后必须收到protocol4、匹配session、cancelled=true回执，才移除控制通道；未确认保留journal并报告CLEANUP_INCOMPLETE。
- journal新增可选ncmBorrowed字段。仅usb0已有共享时借用已有请求，不重新start/stop；其它不明确USB/以太网共享拒绝操作。本次USB模式与Mac服务改动仍有原值和回滚记录；真实接口HTTPS与默认出口条件不变，不据已有共享直接显示可用。此策略替代4.0.5对所有已有usb0一律拒绝，保留用户原共享。
- 清理中owned持续存在，stopping排除有效任务；Stop/Save/Quit等待同一不继承取消的清理任务。只有清理成功和journal保存成功才释放所有权。共享请求停止不再被未知USB读数跳过，USB恢复独立校验归属。
- 安卓在私有filesDir保留有界脱敏JSONL日志并恢复最近500条，Logcat标签USBLinkMic同步阶段；不记录票据、token或原始Intent。Mac记录脱敏am结果，区分命令拒绝、会话登记和取消回执。
