# 界面设计与实现存档

这里保存 USB LinkMic 双端界面的设计定稿与实现渲染，用来在后续改动时对照，避免只能靠文字描述回忆视觉。

## 目录

| 目录 | 内容 |
|---|---|
| `section10-renders/` | 2026-10-27「静如止水，动如雷霆」Section 10 定稿阶段的设计渲染，作为方向确认的依据 |
| `implementation-renders/macos/` | macOS 实际 SwiftUI 实现渲染：全部侧边栏页面明暗两套、设置弹窗、引导向导、菜单栏控制台 |
| `implementation-renders/android/` | Android 实际 Compose 实现渲染：麦克风待命/运行、网络互联、设置、日志、深色模式 |

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

这些是**离屏渲染**，用于检查布局、间距、对比度和明暗模式，不等于设备验收。真机上的字体回退、触控手感、系统深色切换都需另外验证。

界面上不显示任何 `AppSnapshot` 里不存在的实时数据（延迟、速率、丢包率、抖动）。新增指标前先确认契约里有对应字段。
