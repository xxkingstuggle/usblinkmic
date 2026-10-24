# 项目指引

## 项目定位
让 Android 手机通过 USB 或 Wi-Fi 为 Mac 提供麦克风与网络共享能力。

## 如何运行
安装与用户操作见 README.md 和 docs/；Mac、Android 构建入口分别按 Package.swift、android/gradlew 和 scripts/ 中的说明使用。

## 技术栈
macOS 原生 Swift、Android Kotlin/Java、ADB 与 USB 网络转发组件。

## 目录与约定
macOS 源码在 macos/，Android App 在 android/，用户文档在 docs/，打包与图标脚本在 scripts/。

## 当前状态与下一步
修改音频缓冲、USB 命令或跨平台协议时同时检查两端。设备实测未完成前，不要把代码或模拟结果描述成设备验收。
