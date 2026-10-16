# 4.0.7连接状态与控制子协议1

用户明确决定“不需要测试互联网健康，成功连接上就行”，随后授权实施。此条款覆盖原规格中的公网探测成功门槛；冻结原规格、历史测试和T01—T24记录保持不变。

- 能力发现：protocol=4、runtimeRevision>=407、controlRevision=1、受DUMP保护的AdbControlActivity。两端成套升级，不兼容旧控制修订。
- 每个控制JSON请求与响应包含controlRevision=1；身份仍为session与token，取消响应须匹配本次session。控制通道仅loopback/ADB转发；不记录token。
- stop/status的cancelAccepted表示已接受取消；producerStopped表示本次录音已关闭，或VPN服务已销毁并关闭TUN。NCM没有应用内生产者，因此为true，不代表系统USB共享已恢复。
- Mac仅在匹配session且cancelAccepted与producerStopped均true后移除控制通道；否则保留journal及错误供重试。取消已接受但生产者未停时轮询status，避免重复启动取消Activity。
- 未创建会话的匹配取消保留内存墓碑，防止同进程迟到启动。墓碑不跨进程持久化，没有实现requestID或24小时持久墓碑；不得宣称具备这些保证。
- 手机供Mac：真实usb0共享、匹配安卓身份的Mac USB网卡、有效IPv4与carrier active均就绪才报告已连接。默认路由仅展示。监控地址及carrier，短断进入等待恢复，保留资源；不因公网不可达自动拆USB。
- Mac供手机：Android VPN接口与relay隧道实际就绪才报告connected。真正的relay退出、VPN撤销或控制取消仍触发停止/错误。两端不执行公网DNS/HTTP/HTTPS健康请求。
- ncmState.network及反向status.network使用connected/preparing/failed等真实连接阶段。现有NetworkState.available枚举保留兼容设置结构，界面语义改为已连接，不证明公网可达。
- 停止先取消手机任务，再恢复本次拥有的Mac服务、relay、USB与ADB映射；原有共享仅借用不关闭。USB已是原值时跳过重复切换；停止重枚举/确认各5秒阶段预算，不是总停止时长承诺。共享helper回执仍有独立等待，失败保留恢复记录。
- 原默认出口变化只记警告，不等待固定15秒、不改全局路由/Wi-Fi。真实归属变化或恢复失败仍报告CLEANUP_INCOMPLETE，不能冒充停止完成。

取消/重试和资源所有权以macos/Core/SessionController.swift与Android Runtime/Service实际回执为准。未进行功能或竞态测试，用户负责实测。
