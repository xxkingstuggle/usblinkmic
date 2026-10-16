# 当前图标约定 — 2026-10-17

用户指定的新图为assets/branding/app-icon-source.png，Mac和Android统一使用。此决定覆盖2026-10-16沿用旧图标的决定。原图完整保存，SHA256与21个派生尺寸见icon-provenance.json；历史旧图标来源记录保留于icon-provenance-legacy-4.0.2.json，不代表当前资源。

运行python3 scripts/prepare-icons.py从原图经系统sips生成Mac16—1024像素与Android各密度PNG，不重绘、不裁切。Android自适应图标白底/12dp安全边距，普通及圆形launcher均引用新图。Mac使用系统iconutil生成标准ICNS，由CFBundleIconFile引用；启动时加载bundle内图标到applicationIconImage，侧栏品牌使用相同图像。

版本4.0.8/40008/runtime408仅图标、打包与版本更新，protocol4/controlRevision1及音频/供网逻辑保持4.0.7。更新runtime是为了让已安装旧配套的手机在下一次启动功能前更新新图标。不得擅自重置Dock/Finder全局缓存或删除应用数据。
