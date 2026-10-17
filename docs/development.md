# 从源码开始

源码在当前仓库的 main，发布包见 GitHub Release。旧版本的修复过程保留在 Git 历史，没必要为了看源码再找一个旧安装包。

本机记录的构建环境是 Xcode27、Swift6.4、JDK17、Android SDK36、BuildTools35.0.0 和 Gradle8.13。Gradle使用项目wrapper。Android SDK路径放android/local.properties或ANDROID_HOME，不往全局PATH里塞项目路径。

先在自己的环境设置JAVA_HOME，再按顺序构建。以下步骤会重新下载项目依赖并生成本地构建目录。

```sh
./scripts/fetch-tools.sh
swift build
GRADLE_USER_HOME="$PWD/.cache/gradle" ANDROID_USER_HOME="$PWD/android/.android" ./android/gradlew -p android :app:assembleDebug :app:assembleRelease --console=plain
mkdir -p artifacts/relay-classes
find third_party/gnirehtet/relay-java/src/main/java -name '*.java' -print > artifacts/relay-sources.txt
"$JAVA_HOME/bin/javac" -d artifacts/relay-classes @artifacts/relay-sources.txt
"$JAVA_HOME/bin/jar" --create --file artifacts/relay.jar --main-class com.genymobile.gnirehtet.Main -C artifacts/relay-classes .
bash scripts/package.sh 4.0.8-local.1
```

打包目录默认在~/Developer/releases/usblinkmic，已存在的同名目录不会覆盖。Mac包内带APK、ADB、relay和Java运行时。首次打包需要本机JDK17带jlink。发行所需工具版本与来源见toolchain-lock.json和dependencies.md。

Android签名材料在.tools/signing里，属于不能丢的私有文件。维护现有安装时必须继续使用原来的密钥，不能把重新生成签名后无法覆盖升级误当成手机故障。签名材料不进Git，也不进Release。

图标从assets/branding的原图和透明处理图生成。需要重新制作Mac资源时，按branding.md的命令执行，再运行prepare-icons.py。不要靠删除系统缓存掩盖资源或运行时加载问题。

统一检查入口是scripts/validate.sh，会执行Swift和Android检查以及本地relay链路检查。它不能代替真实手机的权限、录音、USB共享和VPN验收。这次发布没有重跑这些测试，保留历史结果，不冒充全项通过。

当前接口约定在contracts，运行编排主要在macos/Core和Android的platform包，UI消费状态。修复时把同一项变更和证据写进Git，别把构建产物提交进去。
