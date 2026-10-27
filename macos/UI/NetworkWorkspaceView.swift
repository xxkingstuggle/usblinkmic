import SwiftUI
import Contracts

struct NetworkWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    let workspace: Workspace
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void
    let onOpenSettings: () -> Void

    private var palette: ZenPalette { ZenPalette(colorScheme) }

    private var deviceDisplayName: String {
        if let id = snapshot.selectedDeviceID,
           let device = snapshot.devices.first(where: { $0.id == id }) {
            return device.name
        }
        if let first = snapshot.devices.first {
            return first.name
        }
        return "Android 手机"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZenWorkspaceHeroHeader(
                    eyebrow: "网络共享",
                    title: "高速有线互联",
                    subtitle: "通过原生 USB NCM 虚拟网卡通道，免安装驱动实现低延迟、零干扰的双向网络共享。"
                )

                if workspace == .phoneInternet {
                    phoneToMacCard
                    macToPhoneCard
                } else {
                    macToPhoneCard
                    phoneToMacCard
                }

                if !snapshot.recoveryMessage.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                        Text("会话安全恢复：\(snapshot.recoveryMessage)")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 816, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
        }
    }

    // MARK: - Card 1: 手机网络提供给 Mac (USB NCM)

    private var phoneToMacCard: some View {
        let status = snapshot.phoneInternet
        let isRunning = status.phase == .running
        let isStoppedOrFailed = status.phase == .stopped || status.phase == .failed
        let stepIndex = activeStepIndex(for: status)

        let subtitleText: String = if isRunning {
            "Mac 正在通过 \(deviceDisplayName) 共享的手机网络上网"
        } else if !status.detail.isEmpty && status.phase != .stopped {
            status.detail
        } else {
            "通过 Android 原生 USB NCM 虚拟网卡将手机蜂窝数据或 Wi-Fi 共享给 Mac"
        }

        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("手机网络提供给 Mac (USB NCM)")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    Text(subtitleText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 16)

                ZenCapsuleActionButton(
                    title: isStoppedOrFailed ? "开启供网" : "停止供网",
                    isStop: !isStoppedOrFailed,
                    width: 138,
                    height: 44,
                    isDisabled: status.phase == .stopping
                ) {
                    send(isStoppedOrFailed ? .start(.phoneInternet) : .stop(.phoneInternet))
                }
            }

            if isRunning || isTaskBusy(status.phase) {
                linkStateWell(
                    primaryText: isRunning ? "NCM 链路已激活" : status.stage,
                    secondaryText: isRunning ? "手机网络出口已就绪" : "正在协商 USB 共享接口"
                )
            } else {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
            }

            HStack(spacing: 0) {
                let steps = ["① USB 就绪", "② NCM 激活", "③ DHCP 分配", "④ 出口连通"]
                ForEach(Array(steps.enumerated()), id: \.offset) { idx, label in
                    let isHighlighted = (isRunning && idx == 3) || (!isRunning && stepIndex == idx)
                    Text(label)
                        .font(.system(size: 12, weight: isHighlighted ? .bold : .regular))
                        .foregroundStyle(isHighlighted ? palette.accentBlue : palette.textSecondary)
                    if idx < steps.count - 1 {
                        Spacer()
                    }
                }
            }

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                Text("错误代码：\(errorCode) · \(status.detail)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.stopCrimson)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .zenCard(isActive: isRunning, cornerRadius: 20)
    }

    // MARK: - Card 2: Mac 网络共享给手机 (反向代理 / VPN)

    private var macToPhoneCard: some View {
        let status = snapshot.macInternet
        let isRunning = status.phase == .running
        let isStoppedOrFailed = status.phase == .stopped || status.phase == .failed

        let subtitleText: String = if isRunning {
            "正在将 Mac 有线/Wi-Fi 宽带通过 USB 隧道高速转发至 \(deviceDisplayName)"
        } else if !status.detail.isEmpty && status.phase != .stopped {
            status.detail
        } else {
            "将 Mac 的 Wi-Fi 或有线宽带通过 USB 隧道提供给 Android 手机使用"
        }

        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Mac 网络共享给手机 (反向代理 / VPN)")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(palette.textPrimary)

                    Text(subtitleText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.textSecondary)
                }

                Spacer(minLength: 16)

                ZenCapsuleActionButton(
                    title: isStoppedOrFailed ? "开启供网" : "停止供网",
                    isStop: !isStoppedOrFailed,
                    width: 138,
                    height: 44,
                    isDisabled: status.phase == .stopping
                ) {
                    send(isStoppedOrFailed ? .start(.macInternet) : .stop(.macInternet))
                }
            }

            if isRunning || isTaskBusy(status.phase) {
                linkStateWell(
                    primaryText: isRunning ? "USB 隧道已连通" : status.stage,
                    secondaryText: isRunning ? "手机端已获得 Mac 网络出口" : "正在建立 VPN 隧道"
                )
            }

            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)

            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("DNS 配置")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Button(action: onOpenSettings) {
                        Text("\(snapshot.settings.dns) (自动)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("路由网段")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Button(action: onOpenSettings) {
                        Text("\(snapshot.settings.routes) (全局代理)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(palette.textPrimary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("手机状态")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                    Text("VPN 权限\(snapshot.vpnPermission.label)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.emeraldGreen)
                }
            }

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                Text("错误代码：\(errorCode) · \(status.detail)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.stopCrimson)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .zenCard(isActive: isRunning, cornerRadius: 20)
    }

    // MARK: - Link State Well (real state only, no fabricated throughput)

    private func linkStateWell(primaryText: String, secondaryText: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(palette.emeraldGreen)
                .frame(width: 7, height: 7)

            Text(primaryText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.textPrimary)

            Text(secondaryText)
                .font(.system(size: 12))
                .foregroundStyle(palette.textSecondary)

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.recessedWell)
        )
    }

    private func activeStepIndex(for status: ModuleStatus) -> Int {
        switch status.phase {
        case .stopped: return -1
        case .checking: return 0
        case .preparing, .waitingUser: return 1
        case .connecting: return 2
        case .running: return 3
        case .stopping: return 1
        case .failed: return 0
        }
    }
}
