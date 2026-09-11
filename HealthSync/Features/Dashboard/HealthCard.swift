import SwiftUI

/// 分类数据卡片组件。
struct HealthCard: View {
    let category: HealthCategory
    let totalTypes: Int
    let enabledCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: category.icon)
                    .foregroundStyle(.tint)
                Spacer()
                Text("\(enabledCount)/\(totalTypes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(category.rawValue)
                .font(.headline)
            ProgressView(value: Double(enabledCount), total: Double(totalTypes))
                .tint(enabledCount > 0 ? .green : .gray)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    HealthCard(category: .activity, totalTypes: 14, enabledCount: 12)
}
