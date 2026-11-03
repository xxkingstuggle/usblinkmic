# USBLinkMic 纯 Wi-Fi 自动连接：真机测试与验收指南

本文档提供版本 **4.0.17**（Wi-Fi Revision 1，审查返工第二轮）纯 Wi-Fi 自动连接功能的真机测试与验收说明。

> [!IMPORTANT]
> **开发安全与隔离承诺**：
> 本次实现严格遵循离线与物理隔离原则，未通过 ADB 连接真机、未替换 `/Applications/USB LinkMic.app`、未干扰现存运行进程 PID `21927`。候选包已独立暂存在 `artifacts/agy-wifi-auto-connect/review-2/4.0.17/`，等待用户主动进行真机测试。
>
> **注意单实例运行**：测试候选 Mac App 时，请先退出原运行的 `/Applications/USB LinkMic.app`（PID 21927），避免两者并发监听 48124/48125 端口产生冲突。

---

## 1. 候选安装包与校验和

候选构建产物位于代码库目录：`artifacts/agy-wifi-auto-connect/review-2/4.0.17/`

| 平台 / 文件 | 路径 | SHA-256 校验和 |
|---|---|---|
| **Android APK** | `artifacts/agy-wifi-auto-connect/review-2/4.0.17/USBLinkMic-4.0.17.apk` | `c3aa9f68e25fbdd4b53dbb1abd18c89fb8a65cef4e7cbba6b2d1ac4acc71f205` |
| **macOS App 归档** | `artifacts/agy-wifi-auto-connect/review-2/4.0.17/USBLinkMic-4.0.17-macOS.zip` | `96ee51c691e316dc5effb0aaddd481ec8ec937bdf4beb8b59e8ce4da11348217` |
| **macOS DMG 镜像** | `artifacts/agy-wifi-auto-connect/review-2/4.0.17/USBLinkMic-4.0.17.dmg` | `79d0a5a6fac41028b65230935ab5bd22caad4d2ec0db32855cd66e3608879c7c` |
| **安装包清单与摘要** | `artifacts/agy-wifi-auto-connect/review-2/4.0.17/manifest.json` | `d8a950285685c0453e4d30f6aae2ba7543f4e438da9053f8cbb023d1446fceff` |

- **校验方法**：在终端运行 `python3 scripts/verify-release.py artifacts/agy-wifi-auto-connect/review-2/4.0.17` 可自动验证全部资源完整性与签名有效性。

---

## 2. 测试前准备与备份

### 2.1 备份现有运行环境
如果后续需要回滚到旧版本：
1. **Mac 端备份**：
   - 现安装应用位于 `/Applications/USB LinkMic.app`。如需备份，执行：
     ```bash
     cp -R "/Applications/USB LinkMic.app" "$HOME/Desktop/USB LinkMic-backup.app"
     ```
2. **Android 端备份**：
   - 当前手机上安装的原版 APK 在 Mac 备份位置：
     `/Applications/USB LinkMic.app/Contents/Resources/companion.apk`
     （SHA-256: `2643069518c0d84916890887cbdb9aee0dcc25ea58dc53e43f455fc089d9b4bb`）

### 2.2 测试环境网络配置要求
支持以下两种可互通网络环境之一：
- **场景 A（推荐）：家庭/办公普通 Wi-Fi**：手机与 Mac 连接到同一个无线路由器，且路由器未开启“AP 隔离”或“访客模式”。
- **场景 B：Android 手机热点**：Android 手机开启便携式热点，Mac 搜索并加入该热点 Wi-Fi。

---

## 3. 真机测试用例与验收步骤

### 用例 1：首次配对与安全授权（6 位码比对）
1. **安装并打开**：
   - 将 `USBLinkMic-4.0.17.apk` 安装到 Android 手机并打开应用。
   - 解压或挂载 `USBLinkMic-4.0.17.dmg`，启动候选 `USB LinkMic.app`。
   - **完全拔掉 USB 数据线**，确认 `adb devices` 没有任何连接。
2. **观察自动发现**：
   - Android 界面上的“局域网自动连接”处于开启状态，几秒内应自动发现 Mac 广播的 `_usblinkmic._tcp` 服务。
3. **安全确认交互**：
   - 手机端界面显示正在发起的 Mac 名称与 **6 位数字校验码**，处于“等待在 Mac 上确认配对…”状态（手机端无多余确认按钮，以手机为主体发起展示）。
   - Mac 端弹出配对授权横幅/弹窗，显示待配对手机名称与 **6 位数字校验码**。
   - **核对两端 6 位数字必须完全一致**后，在 Mac 端点击“允许配对”。
4. **通过判定**：
   - 两端建立双向信任并持久化保存公钥凭据；
   - 手机端自动启动前台录音服务并开始向 Mac 传输音频；
   - Mac 端状态变为“正在接收音频”，帧数稳定增长，电平表跳动。

---

## 4. 日常使用与自愈验收

### 用例 2：免配置自动连接（日常使用体验）
1. **前置条件**：已通过【用例 1】完成首次信任配对。
2. **测试操作**：
   - 将手机 App 和 Mac App 分别完全退出（手机划掉后台任务卡片，Mac 退出应用）。
   - 拔出 USB 数据线（确保处于纯无线状态）。
   - 打开手机 App，再打开 Mac App（或先开 Mac 再开手机，分别测试两次）。
3. **通过判定**：
   - 无需再次确认配对码、无需输入 IP 地址、无需任何手动点击；
   - 10 秒内两端自动完成服务发现、互相鉴权、准备接收器并开始拾音传输；
   - Mac 菜单栏和主界面正确显示手机设备名与音频电平。

---

### 用例 3：手动停止与防意外自动恢复
1. **测试操作**：
   - 在正在无线采音的状态下，在手机端或 Mac 端点击“停止”。
   - 观察 60 秒，期间随意切换 App 界面、锁屏、点亮屏幕。
2. **通过判定**：
   - 两端停止采音并保持在就绪/暂停状态（`WifiAutoPhase.PAUSED`）；
   - 自动连接不会擅自覆盖用户的“停止”意图重新唤醒录音；
   - 当用户再次主动点击“开始拾音”时，能够正常恢复无线录音。

---

### 用例 4：短断网与 IP 漂移自愈
1. **测试操作**：
   - 在正常无线采音时，将手机 Wi-Fi 开关关闭 5 秒，然后再重新打开；
   - 或者在路由器后台为手机/Mac 重新分配不同 IP，或关闭热点重开。
2. **通过判定**：
   - 断网瞬间两端及时感知并清理旧连接；
   - 连网恢复后，NSD 发现自动解析新 IP，双方使用保存的公钥再次自动握手恢复音频流，无需手动干预。

---

### 用例 5：热点模式实测
1. **测试操作**：
   - 手机打开移动热点，Mac 连接手机热点。
   - 启动两端 App，验证在 Android 热点网络拓扑下，系统 NSD 与 Bonjour 能否顺利发现和互联。
2. **通过判定**：
   - 若系统 NSD 广播与解析顺畅，能像普通 Wi-Fi 一样 10 秒内完成发现并稳定传输音频。

---

## 5. 故障排查与诊断导出

- **Mac 端日志**：在 Mac App 的“设备与日志”页面点击“导出诊断日志”或“拷贝日志”，可查看 `[wifi/auto]` 模块的连接与认证事件（所有密钥、token、nonce 均已由 `LogRedactor` 自动脱敏打码）。
- **Android 端日志**：在手机 App 界面底部查看诊断日志，确认 NSD 发现、握手与传输日志。
- **取消设备配对**：
  - Mac 端：在“设备与日志” -> “可信手机设备”列表中点击“解除信任”。
  - Android 端：在设置页面的“已信任的 Mac”列表中点击“解除信任”。

---

## 6. 回滚指南

如需彻底回滚到测试前状态：
1. **Mac 端**：
   - 退出 4.0.17 版本的候选应用；
   - 删除临时信任文件：`rm -f "$HOME/Library/Application Support/USBLinkMic-v4/wifi-trust.json"`；
   - 重新从备份中恢复 `/Applications/USB LinkMic.app` 启动即可。
2. **Android 端**：
   - 若仅需关闭自动连接功能：直接在应用内设置页关闭“Wi-Fi 自动连接”开关即可恢复原 USB/ADB 单一工作流，无须卸载应用；
   - 若需要降级回原版本：可直接安装原版 `companion.apk`（若遇到系统降级版本保护，先卸载后再安装原版 `companion.apk`）。
