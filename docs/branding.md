# 图标资源

两端图标源文件位于 `assets/branding/app-icon-source.png`，派生资源及 SHA256 记录在 [icon-provenance.json](icon-provenance.json)。

## macOS

`mac-app-icon.png` 是透明背景的 Mac 图标源图。`prepare-mac-icon.swift` 裁剪底板并保留透明边距，输出 `mac-app-icon-prepared.png`。1024 像素画布中，底板占 820 像素，四边各留 102 像素。

```sh
swift scripts/prepare-mac-icon.swift assets/branding/mac-app-icon.png assets/branding/mac-app-icon-prepared.png
python3 scripts/prepare-icons.py
```

Mac 图标集包含 10 个尺寸，打包时使用系统 `iconutil` 生成 `AppIcon.icns`。应用同时包含 `DockIcon.png`，启动和窗口出现时加载，逻辑尺寸为 128 点。

## Android

Android 从源图生成各密度、圆形及自适应图标。自适应图标保留 12dp 安全边距，派生资源由 `scripts/prepare-icons.py` 生成。

替换源图后，需要重新生成两端资源并更新 `icon-provenance.json` 中的指纹。
