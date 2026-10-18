# 图标资源

Android 原图保留在 `assets/branding/app-icon-source.png`。Mac 使用单独的母版 `assets/branding/mac-app-icon.png`，两端资源及 SHA256 记录在 [icon-provenance.json](icon-provenance.json)。

## macOS

Mac 母版是没有内嵌圆角、阴影或外边距的实心正方形图像。图案保留蓝色手机、连接线和带声波的电脑；生成要求记录在 [母版提示词](../assets/branding/mac-icon-generation.txt)。

`prepare-mac-icon.swift` 将完整母版绘制到 1024 像素画布中 824 像素的底板上，仅应用一次圆角轮廓，四边各留 100 像素透明边距。不再对抠图残稿二次裁剪、填白或叠加轮廓。

```sh
swift scripts/prepare-mac-icon.swift assets/branding/mac-app-icon.png assets/branding/mac-app-icon-prepared.png
python3 scripts/prepare-icons.py --mac-only
```

Mac 图标集包含 10 个尺寸。打包时使用系统 `iconutil` 生成 `AppIcon.icns`，由 `Info.plist` 的 `CFBundleIconFile` 引用。应用不再包含或加载 `DockIcon.png`，也不再设置 `NSApp.applicationIconImage`，让系统为 Finder、Dock 和应用切换器选择合适的图标尺寸。

## Android

Android 从原图生成各密度、圆形及自适应图标。自适应图标保留 12dp 安全边距。仅修改 Mac 图标时使用 `--mac-only`，保留 Android 图像与指纹。

同时重建两端资源可运行 `python3 scripts/prepare-icons.py`。替换母版后，需要重新生成对应资源并更新 `icon-provenance.json` 中的指纹。
