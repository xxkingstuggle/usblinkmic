# 界面设计与实现存档

> **历史归档说明**：本目录下保存的 Section 10 设计定稿（2026-10-27）与实现离屏渲染（Git 提交 `d90c35a`，2026-10-27）均为历史归档材料，保留供视觉回溯与布局参考。它们**不代表 4.0.16 当前现役 UI**（4.0.16 已取消统一偏好设置弹窗，将选项收归各工作区页内且默认折叠高级选项，并将麦克风页手机控制端口设为只读）。当前现役界面以 [使用指南](../install.md) 及当前源码为准。

这里保存 USB LinkMic 双端界面的设计定稿与实现渲染，用来在后续改动时对照，避免只能靠文字描述回忆视觉。

## 目录

| 目录 | 内容 |
|---|---|
| `section10-renders/` | 2026-10-27「静如止水，动如雷霆」Section 10 定稿阶段的设计渲染，作为历史方向确认依据 |
| `implementation-renders/macos/` | 2026-10-27 归档的 macOS 历史 SwiftUI 实现离屏渲染：含旧版设置弹窗、引导向导等（不代表 4.0.16 现役页内设置结构） |
| `implementation-renders/android/` | 2026-10-27 归档的 Android 历史 Compose 实现离屏渲染：麦克风待命/运行、网络互联、设置、日志、深色模式 |

## 怎么重新生成

macOS：

```sh
swift test --filter RenderTests
```

产物写入 `artifacts/ui-renders/`（已被 .gitignore，不随仓库保存）。

Android（无需真机或模拟器，Robolectric 离屏渲染）：

```sh
cd android && ./gradlew testDebugUnitTest --tests "com.zjx.usblinkmic.ui.AndroidUi*"
```

产物写入 `android/app/build/ui-renders/`。

## 注意

这些是 2026-10-27 阶段的**离屏渲染**历史归档，用于检查当时的布局、间距、对比度和明暗模式，不等于设备验收，也不代表 4.0.16 最终界面的文案与页内布局（例如 4.0.16 麦克风页手机控制端口已改为只读）。真机上的字体回退、触控手感、系统深色切换都需另外验证。

界面上不显示任何 `AppSnapshot` 里不存在的实时数据（延迟、速率、丢包率、抖动）。新增指标前先确认契约里有对应字段。
