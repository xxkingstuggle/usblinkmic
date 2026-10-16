# 当前图标约定 — 2026-10-17

用户指定的新图为assets/branding/app-icon-source.png，Mac和Android统一使用。此决定覆盖2026-10-16沿用旧图标的决定。原图完整保存，SHA256与21个派生尺寸见icon-provenance.json；历史旧图标来源记录保留于icon-provenance-legacy-4.0.2.json，不代表当前资源。

运行python3 scripts/prepare-icons.py从原图经系统sips生成Mac16—1024像素与Android各密度PNG，不重绘、不裁切。Android自适应图标白底/12dp安全边距，普通及圆形launcher均引用新图。Mac使用系统iconutil生成标准ICNS，由CFBundleIconFile引用；由系统按标准ICNS显示，禁止将原始ICNS直接覆盖applicationIconImage；侧栏使用NSWorkspace系统图标并限制24点。

版本4.0.8/40008/runtime408仅图标、打包与版本更新，protocol4/controlRevision1及音频/供网逻辑保持4.0.7。更新runtime是为了让已安装旧配套的手机在下一次启动功能前更新新图标。不得擅自重置Dock/Finder全局缓存或删除应用数据。

4.0.8-review.2：Mac显示修正，撤销运行时原始ICNS覆盖，保留系统外形和留白；侧栏32→24点。原图、两端图标资源、Android APK及协议/业务逻辑不变，版本仍4.0.8，按review.2与sourceCommit区分包。

4.0.8-review.3覆盖review.2的Mac显示策略：用户截图证实Dock为占位图。Mac图像经透明底处理与几何圆角遮罩，1024画布内820像素底板/102像素透明留白；DockIcon.png明确加载并设128点逻辑尺寸，再刷新DockTile。标准ICNS同时保留。Android不变；版本仍4.0.8，以review.3/源码commit区分。原始生成透明边缘有碎屑，已用固定圆角边界去掉，不直接交付该草稿。
