import SwiftUI
import HealthKit
import UIKit

/// 设置页：服务器连接 / 数据范围 / 同步控制 / 外观 / 关于
struct SettingsView: View {
    @Environment(HermesSettings.self) private var settings
    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL
    @State private var showSyncResult = false
    @State private var syncResultMessage = ""
    @State private var syncResultOK = false
    @State private var testing = false
    @State private var testResult: String?

    /// 从 Info.plist 读取真实版本号（部署验证用）。
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }

    private var authorizationTitle: String {
        switch state.healthAuthorizationState {
        case .notRequested: return "请求健康数据权限"
        case .requested: return "健康权限已请求"
        case .unavailable: return "重新请求健康权限"
        }
    }

    private var authorizationIcon: String {
        switch state.healthAuthorizationState {
        case .notRequested: return "lock.shield.fill"
        case .requested: return "checkmark.shield.fill"
        case .unavailable: return "exclamationmark.shield.fill"
        }
    }

    private var authorizationBadge: String {
        switch state.healthAuthorizationState {
        case .notRequested: return "未请求"
        case .requested: return "已请求"
        case .unavailable: return "请求失败"
        }
    }

    private var authorizationColor: Color {
        switch state.healthAuthorizationState {
        case .notRequested: return .secondary
        case .requested: return .blue
        case .unavailable: return .red
        }
    }

    /// 通过需要鉴权的 ingest 接口验证地址、TLS 路径和 Token。
    private func testConnection() async {
        testing = true
        testResult = nil
        defer { testing = false }
        guard let address = settings.serverAddress else {
            testResult = "失败：地址或端口格式错误"
            return
        }
        let token = settings.normalizedAPIToken
        guard !token.isEmpty else {
            testResult = "失败：API Token 为空"
            return
        }

        do {
            let elapsed = try await HTTPSyncService().testConnection(address: address, token: token)
            testResult = String(format: "成功：%.0f ms", elapsed * 1_000)
            await BackgroundSyncManager.shared.refreshBackgroundConfiguration()
        } catch let error as SyncNetworkError {
            testResult = "失败：\(error.localizedDescription)"
        } catch {
            let nsError = error as NSError
            let detail: String
            switch nsError.code {
            case NSURLErrorTimedOut:
                detail = "超时（防火墙未放行该端口？）"
            case NSURLErrorCannotConnectToHost:
                detail = "连不上主机（地址错/服务未启动）"
            case NSURLErrorCannotFindHost:
                detail = "找不到主机（DNS/地址错）"
            case NSURLErrorNotConnectedToInternet:
                detail = "无网络连接"
            default:
                detail = nsError.localizedDescription
            }
            testResult = "失败：\(detail)"
        }
    }

    /// 一键把服务器地址/端口/Token 恢复为空默认值并写回存储。
    /// 用户需自行填写自己的服务器地址与 Token（无内置默认服务器）。
    private func resetToDefaultServer() {
        settings.serverHost = ""
        settings.serverPort = "443"
        settings.serverScheme = "https"
        settings.apiToken = ""
        settings.persist()
        testResult = "已重置：请填写你自己的服务器地址与 Token"
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - 服务器连接
                Section {
                    Picker("协议", selection: Bindable(settings).serverScheme) {
                        Text("HTTPS").tag("https")
                        Text("HTTP").tag("http")
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.serverScheme) { _, _ in settings.persist() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("服务器地址")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("例如 example.com 或 https://example.com:8443",
                                  text: Bindable(settings).serverHost)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit { settings.persist() }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("端口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("443", text: Bindable(settings).serverPort)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numberPad)
                            .onSubmit { settings.persist() }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Token")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SecureField("Token", text: Bindable(settings).apiToken)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { settings.persist() }
                    }
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Label("测试连接", systemImage: "wifi.exclamationmark")
                            Spacer()
                            if testing {
                                ProgressView()
                            } else if let r = testResult {
                                Text(r)
                                    .font(.caption)
                                    .foregroundStyle(r.hasPrefix("成功") ? .green : .red)
                            }
                        }
                    }
                    .disabled(testing)
                    Button {
                        resetToDefaultServer()
                    } label: {
                        Label("恢复默认服务器", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Label("服务器连接", systemImage: "server.rack")
                } footer: {
                    Text("当前目标：\(settings.ingestURL?.absoluteString ?? "请填写有效地址")")
                }

                // MARK: - 数据范围
                Section {
                    Picker("同步模式", selection: Bindable(settings).syncMode) {
                        ForEach(SyncMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: settings.syncMode) { _, _ in settings.persist() }
                    Picker("回溯范围", selection: Bindable(settings).lookback) {
                        ForEach(LookbackRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .onChange(of: settings.lookback) { _, _ in settings.persist() }
                    NavigationLink {
                        DataTypePickerView(selected: Bindable(settings).enabledTypes) {
                            settings.persist()
                        }
                    } label: {
                        HStack {
                            Text("数据类型")
                            Spacer()
                            Text("\(settings.enabledTypes.count) 项")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("数据范围", systemImage: "scope")
                }

                // MARK: - 同步控制
                Section {
                    Toggle("打开 App 自动同步", isOn: Bindable(settings).autoSyncOnActive)
                        .onChange(of: settings.autoSyncOnActive) { _, _ in settings.persist() }
                    Toggle("后台自动同步", isOn: Bindable(settings).backgroundSyncEnabled)
                        .onChange(of: settings.backgroundSyncEnabled) { _, enabled in
                            settings.persist()
                            Task {
                                if enabled {
                                    await BackgroundSyncManager.shared.refreshBackgroundConfiguration()
                                } else {
                                    await BackgroundSyncManager.shared.disableBackgroundWork()
                                }
                            }
                        }
                    Toggle("上传失败自动重试", isOn: Bindable(settings).retryFailedUploads)
                        .onChange(of: settings.retryFailedUploads) { _, _ in settings.persist() }

                    Button {
                        Task {
                            let result = await SyncCoordinator.shared.syncNowWithResult()
                            switch result {
                            case .success:
                                syncResultOK = true
                                syncResultMessage = "同步完成：\(state.totalSamples) 条 / \(state.uploadedBatches) 批"
                            case .failed(let msg):
                                syncResultOK = false
                                syncResultMessage = msg.isEmpty ? "同步失败，请检查网络与服务器" : msg
                            case .alreadySyncing:
                                syncResultOK = false
                                syncResultMessage = "正在同步中，请稍候"
                            }
                            showSyncResult = true
                        }
                    } label: {
                        HStack {
                            Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if state.syncPhase == .syncing {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(state.syncPhase == .syncing)
                } header: {
                    Label("同步控制", systemImage: "bolt.fill")
                } footer: {
                    if let last = state.lastSyncAt {
                        Text("上次同步：\(last.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if state.totalSamples > 0 {
                        Text("累计样本：\(state.totalSamples) 条，批次：\(state.uploadedBatches)")
                    }
                }

                // MARK: - 外观
                Section {
                    Picker("外观", selection: Bindable(settings).colorScheme) {
                        ForEach(AppColorScheme.allCases) { scheme in
                            Text(scheme.displayName).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Label("外观", systemImage: "paintbrush.fill")
                }

                // MARK: - 权限
                Section {
                    Button {
                        Task {
                            await SyncCoordinator.shared.requestAuthIfNeeded()
                        }
                    } label: {
                        HStack {
                            Label(authorizationTitle, systemImage: authorizationIcon)
                            Spacer()
                            Text(authorizationBadge)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(authorizationColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(authorizationColor)
                        }
                    }
                    if state.healthAuthorizationState == .requested {
                        Button {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        } label: {
                            Label("打开系统健康权限设置", systemImage: "gear")
                        }
                    }
                } header: {
                    Label("健康权限", systemImage: "lock.shield.fill")
                } footer: {
                    Text("iOS 不会向 App 透露只读健康权限的最终授予状态。显示“已请求”表示系统授权流程已完成，不代表每种数据都已允许读取。")
                }

                // MARK: - 关于
                Section {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("目标服务", value: "Hermes Health API v2")
                } header: {
                    Label("关于", systemImage: "info.circle.fill")
                }
            }
            .navigationTitle("设置")
            .onChange(of: settings.enabledTypes) { _, _ in
                Task { await BackgroundSyncManager.shared.refreshBackgroundConfiguration() }
            }
            .task {
                // 设置页出现时读取 HealthKit 真实授权状态并刷新 UI（问题 1）。
                await SyncCoordinator.shared.refreshHealthAuthStatus()
                await BackgroundSyncManager.shared.refreshBackgroundConfiguration()
            }
            .alert("同步结果", isPresented: $showSyncResult) {
                Button("好", role: .cancel) {}
            } message: {
                Text(syncResultMessage)
            }
        }
    }
}

/// 数据类型选择页：按分类分组，敏感类型标记，数据存在与最近一次时间标注。
/// 女性健康分类仅在用户生物学性别为女性时显示。
struct DataTypePickerView: View {
    @Binding var selected: Set<HealthDataType>
    var onPersist: () -> Void = {}
    @State private var hasData: [HealthDataType: Bool] = [:]
    @State private var latestDate: [HealthDataType: Date] = [:]
    @State private var latestValue: [HealthDataType: String] = [:]
    @State private var checking = false
    @State private var biologicalSex: HKBiologicalSex = .notSet

    /// 按性别过滤分组：女性健康分类仅女性可见。
    private var grouped: [(HealthCategory, [HealthDataType])] {
        HealthCategory.allCases.compactMap { category in
            // 女性健康分类：若已确认为非女性则跳过整个分类
            if category == .reproductiveHealth, biologicalSex != .female {
                return nil
            }
            let items = HealthDataType.allCases.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    var body: some View {
        List {
            if checking {
                HStack {
                    Spacer()
                    ProgressView("正在检查数据…")
                    Spacer()
                }
            }
            // 性别未知时提示（便于用户理解为何/如何显示女性健康）
            if biologicalSex != .female {
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                        Text("按健康档案的生物学性别显示数据类型。女性健康相关类型仅在档案为女性时展示。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(grouped, id: \.0) { category, items in
                Section(category.rawValue) {
                    ForEach(items) { type in
                        Toggle(isOn: Binding(
                            get: { selected.contains(type) },
                            set: { on in
                                if on { selected.insert(type) }
                                else { selected.remove(type) }
                                onPersist()
                            }
                        )) {
                            HStack {
                                Text(type.displayName)
                                if let has = hasData[type] {
                                    if has {
                                        if let value = latestValue[type], !value.isEmpty {
                                            Text("最近 " + value)
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else if let date = latestDate[type] {
                                            Text("最近 " + date.formatted(date: .numeric, time: .shortened))
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        } else {
                                            Text("已开启")
                                                .font(.caption2)
                                                .foregroundStyle(.green)
                                        }
                                    } else {
                                        Text("无数据")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("检查中…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if type.isSensitive {
                                    Text("敏感")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.orange.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("数据类型")
        .task {
            // 先读性别（决定显示哪些分类），再做数据存在性检查
            biologicalSex = await SyncCoordinator.shared.loadBiologicalSex()
            await checkDataAvailability()
        }
    }

    private func checkDataAvailability() async {
        checking = true
        var has: [HealthDataType: Bool] = [:]
        var latest: [HealthDataType: Date] = [:]
        var values: [HealthDataType: String] = [:]
        // 按性别过滤后再检查，跳过当前性别看不到的分类（省时）
        let visibleTypes = grouped.flatMap { $0.1 }
        for type in visibleTypes {
            let info = await SyncCoordinator.shared.hasSamples(for: type)
            has[type] = info.hasData
            if let date = info.latestDate {
                latest[type] = date
            }
            if let value = info.latestValue, !value.isEmpty {
                values[type] = value
            }
        }
        hasData = has
        latestDate = latest
        latestValue = values
        checking = false
    }
}

#Preview {
    SettingsView()
        .environment(HermesSettings())
        .environment(AppState.shared)
}
