# 当前图标约定 — 2026-10-17

用户指定assets/branding/app-icon-source.png作为两端图案。Android继续用原图派生各密度、圆形和自适应图标，自适应保留12dp安全边距。旧图标来源仅保留于icon-provenance-legacy-4.0.2.json，不代表当前资源。

Mac当前策略为4.0.8-review.4：经imagegen处理外侧透明背景，生成资产mac-app-icon.png；用scripts/prepare-mac-icon.swift去掉边缘碎屑、裁剪底板，输出mac-app-icon-prepared.png。1024像素RGBA画布内820像素圆角底板，四边102像素透明。原蓝色图案保留，未改Android。由prepare-icons.py和系统sips派生10个Mac尺寸，系统iconutil生成ICNS。

包内同时包含AppIcon.icns和DockIcon.png。启动完成及SwiftUI窗口onAppear明确加载PNG，逻辑尺寸固定128点，设置applicationIconImage并刷新DockTile；专用branding日志记录实际应用。侧栏24点，使用系统图标。禁止再直接加载不透明满画布原图，也不能仅删除加载代码后假定系统一定显示成功。

review.2删除加载后用户截图出现占位图；review.3仅有构建/安装记录，未找到加载日志。review.4已取得运行进程branding日志，说明已加载固定尺寸透明图标。Dock工具画面仍不可读，不冒充目视验收。版本仍4.0.8/40008，以review.4与sourceCommit区分，音频/供网不变。

来源、派生路径及SHA见icon-provenance.json。重新制作：先运行`swift scripts/prepare-mac-icon.swift assets/branding/mac-app-icon.png assets/branding/mac-app-icon-prepared.png`，再运行`python3 scripts/prepare-icons.py`。不清全局Dock/Finder缓存、不改用户Dock大小或应用数据。
