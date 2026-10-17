# 构建与开发

源码维护在 main，安装包发布在 [Releases](https://github.com/xxkingstuggle/usblinkmic/releases)。

已使用的构建环境为 Xcode27、Swift6.4、JDK17、Android SDK36、BuildTools35.0.0 和 Gradle8.13。Gradle 使用项目 wrapper，通过 android/local.properties 或 ANDROID_HOME 配置 Android SDK。

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

Android 签名材料保存在 .tools/signing。更新已有安装时必须使用原签名密钥；更换密钥后，已有 Android 安装无法直接覆盖升级。签名材料不要提交到 Git 或 Release。

图标从 assets/branding 的源图生成，派生步骤见 [图标资源](branding.md)。

统一检查入口是 scripts/validate.sh，执行 Swift、Android 及本地 relay 链路检查。真实手机的权限、录音、USB 共享和 VPN 需要另外验证，场景见 [验收矩阵](acceptance.md)。

接口约定在 contracts，运行编排主要在 macos/Core 和 Android 的 platform 包，UI 消费状态。提交改动时，请附上复现步骤与验证方式，构建产物不要提交到源码仓库。
