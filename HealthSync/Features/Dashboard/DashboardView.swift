import SwiftUI

/// 概览页：最近同步摘要 + 分类卡片。
struct DashboardView: View {
    @Environment(AppState.self) private var state
    @Environment(HermesSettings.self) private var settings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    syncStatusCard
                    categoriesGrid
                }
                .padding()
            }
            .navigationTitle("HealthSync")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        SyncCoordinator.shared.syncNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.syncPhase == .syncing)
                }
            }
        }
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("同步状态", systemImage: "bolt.heart.fill")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            switch state.syncPhase {
            case .idle:
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text("等待同步")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .checkingAuth:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("检查权限中…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .syncing:
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                Text("正在同步 \(state.currentType)… \(Int(state.progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.totalSamples > 0 {
                    Text("已上传 \(state.uploadedBatches) 批 · 共 \(state.totalSamples) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .success:
                Label("同步成功", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Label("同步失败", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let last = state.lastSyncAt {
                Text("上次成功同步：\(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state.syncPhase {
        case .syncing:
            Circle().fill(.blue).frame(width: 10, height: 10)
        case .success:
            Circle().fill(.green).frame(width: 10, height: 10)
        case .failed:
            Circle().fill(.red).frame(width: 10, height: 10)
        default:
            Circle().fill(.gray).frame(width: 10, height: 10)
        }
    }

    private var categoriesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(HealthCategory.allCases) { category in
                let types = HealthDataType.allCases.filter { $0.category == category }
                let enabledCount = types.filter { settings.enabledTypes.contains($0) }.count
                HealthCard(category: category, totalTypes: types.count, enabledCount: enabledCount)
            }
        }
    }
}

#Preview {
    DashboardView()
        .environment(HermesSettings())
        .environment(AppState())
}
