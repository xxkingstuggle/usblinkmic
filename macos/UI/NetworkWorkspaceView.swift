import SwiftUI
import Contracts

struct NetworkWorkspaceView: View {
    let workspace: Workspace
    let snapshot: AppSnapshot
    let send: (UserAction) -> Void
    let onOpenSettings: () -> Void

    private var status: ModuleStatus {
        workspace == .phoneInternet ? snapshot.phoneInternet : snapshot.macInternet
    }

    private var effectiveNetworkState: NetworkState {
        status.phase == .stopped ? .stopped : snapshot.networkState
    }

    private var isStoppedOrFailed: Bool {
        status.phase == .stopped || status.phase == .failed
    }

    private var pipelineSteps: [String] {
        if workspace == .phoneInternet {
            return ["USB 能力检查", "NCM 共享激活", "DHCP 地址分配", "Mac 出口就绪"]
        } else {
            return ["本地转发启动", "手机 VPN 授权", "隧道接口建立", "手机出口就绪"]
        }
    }

    private var activeStepIndex: Int {
        switch status.phase {
        case .stopped:
            return -1
        case .checking:
            return 0
        case .preparing, .waitingUser:
            return 1
        case .connecting:
            return effectiveNetworkState == .addressed || effectiveNetworkState == .verifying ? 2 : 1
        case .running:
            return 3
        case .stopping:
            return 1
        case .failed:
            return 0
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroNetworkCard
                linkDetailsSection
                if workspace == .macInternet {
                    vpnAndRoutingSection
                } else {
                    ncmProtectionSection
                }
                if !snapshot.recoveryMessage.isEmpty {
                    recoverySection
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Hero Network Card

    private var heroNetworkCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(status.phase.tint.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Image(systemName: workspace.symbol)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(status.phase.tint)
                        .symbolRenderingMode(.hierarchical)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(status.stage.isEmpty ? status.phase.label : status.stage)
                            .font(.title3.weight(.semibold))
                        StatusPill(
                            label: status.phase.label,
                            symbol: status.phase.symbol,
                            tint: status.phase.tint
                        )
                        StatusPill(
                            label: effectiveNetworkState.label,
                            symbol: effectiveNetworkState.symbol,
                            tint: effectiveNetworkState.tint
                        )
                    }

                    Text(
                        status.detail.isEmpty
                            ? workspace.subtitle
                            : status.detail
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    send(isStoppedOrFailed ? .start(workspace) : .stop(workspace))
                } label: {
                    Label(
                        isStoppedOrFailed ? "开始共享" : "停止共享",
                        systemImage: isStoppedOrFailed ? "play.fill" : "stop.fill"
                    )
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(isStoppedOrFailed ? .accentColor : .red)
                .controlSize(.large)
                .disabled(status.phase == .stopping)
            }

            Divider()
                .opacity(0.55)

            // 4-Stage Pipeline Stepper
            HStack(spacing: 8) {
                ForEach(Array(pipelineSteps.enumerated()), id: \.offset) { index, title in
                    pipelineStepBadge(index: index, title: title)
                    if index < pipelineSteps.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let errorCode = status.errorCode, !errorCode.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("错误代码：\(errorCode)")
                            .font(.callout.weight(.semibold))
                        Text(status.detail.isEmpty ? "请前往「诊断日志」查看详细失败阶段与恢复建议。" : status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(18)
        .heroGlassSurface(tint: status.phase.tint)
    }

    private func pipelineStepBadge(index: Int, title: String) -> some View {
        let isCompleted = status.phase == .running || (activeStepIndex > index && status.phase != .failed)
        let isCurrent = activeStepIndex == index && status.phase != .stopped && status.phase != .running
        let isFailed = status.phase == .failed && activeStepIndex == index

        let tint: Color = if isFailed {
            .red
        } else if isCompleted {
            .green
        } else if isCurrent {
            .blue
        } else {
            .secondary
        }

        let symbol: String = if isFailed {
            "xmark.circle.fill"
        } else if isCompleted {
            "checkmark.circle.fill"
        } else if isCurrent {
            "circle.dotted.circle.fill"
        } else {
            "\(index + 1).circle"
        }

        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(isCurrent || isCompleted ? .semibold : .regular))
                .foregroundStyle(isCurrent || isCompleted ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            tint.opacity(isCurrent || isCompleted || isFailed ? 0.12 : 0.05),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - Grouped Details Sections

    private var linkDetailsSection: some View {
        NativeGroupedSection("链路状态与说明") {
            NativeSettingRow(
                title: "当前任务阶段",
                subtitle: status.detail.isEmpty ? "展示当前网络共享握手与恢复进度" : status.detail,
                symbol: "bolt.horizontal.fill",
                symbolTint: status.phase.tint
            ) {
                StatusPill(
                    label: status.stage.isEmpty ? status.phase.label : status.stage,
                    tint: status.phase.tint
                )
            }

            NativeSettingRow(
                title: "网络通道可用性",
                subtitle: effectiveNetworkState.explanation,
                symbol: effectiveNetworkState.symbol,
                symbolTint: effectiveNetworkState.tint,
                showDivider: false
            ) {
                StatusPill(
                    label: effectiveNetworkState.label,
                    symbol: effectiveNetworkState.symbol,
                    tint: effectiveNetworkState.tint
                )
            }
        }
    }

    private var vpnAndRoutingSection: some View {
        NativeGroupedSection("VPN 授权与路由配置") {
            NativeSettingRow(
                title: "手机端 VPN 隧道授权",
                subtitle: "首次启动时需在手机系统弹窗中确认 VPN 连接请求",
                symbol: "lock.shield.fill",
                symbolTint: snapshot.vpnPermission.tint
            ) {
                StatusPill(
                    label: snapshot.vpnPermission.label,
                    symbol: snapshot.vpnPermission.symbol,
                    tint: snapshot.vpnPermission.tint
                )
            }

            NativeSettingRow(
                title: "DNS 服务器 IPv4",
                subtitle: "下发给手机 VPN 接口的解析服务器地址",
                symbol: "server.rack",
                symbolTint: .blue
            ) {
                Text(snapshot.settings.dns)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            NativeSettingRow(
                title: "转发路由 CIDR",
                subtitle: "控制哪些 IPv4 网段经由 Mac 网络出口转发",
                symbol: "point.3.connected.trianglepath.dotted",
                symbolTint: .indigo,
                showDivider: false
            ) {
                HStack(spacing: 8) {
                    Text(snapshot.settings.routes)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("路由设置…", action: onOpenSettings)
                        .controlSize(.small)
                }
            }
        }
    }

    private var ncmProtectionSection: some View {
        NativeGroupedSection("USB NCM 共享与恢复保护") {
            NativeSettingRow(
                title: "物理传输接口",
                subtitle: "通过 Android 11+ 原生 USB NCM 协议建立虚拟以太网 (usb0)",
                symbol: "cable.connector.horizontal",
                symbolTint: .teal
            ) {
                ParameterTag("USB NCM")
            }

            NativeSettingRow(
                title: "安全恢复边界",
                subtitle: "停止或退出时仅恢复本次会话修改的 USB 模式与 Mac 网络服务，不改动其他网络顺序",
                symbol: "checkmark.shield.fill",
                symbolTint: .green,
                showDivider: false
            ) {
                StatusPill(label: "自动恢复已启用", tint: .green)
            }
        }
    }

    private var recoverySection: some View {
        NativeGroupedSection("会话恢复记录") {
            NativeSettingRow(
                title: "上次会话清理状态",
                subtitle: snapshot.recoveryMessage,
                symbol: "arrow.uturn.backward.circle.fill",
                symbolTint: .orange,
                showDivider: false
            ) {
                EmptyView()
            }
        }
    }
}
