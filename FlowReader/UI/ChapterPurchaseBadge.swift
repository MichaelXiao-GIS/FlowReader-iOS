import SwiftUI

/// A VIP chapter is not necessarily unpurchased; only confirmed account data may show a lock.
struct ChapterPurchaseBadge: View {
    @Environment(CloudLibraryStore.self) private var cloud
    let chapter: Chapter

    @ViewBuilder var body: some View {
        if chapter.isVIP {
            Group {
                switch cloud.purchaseState(for: chapter) {
                case .purchased:
                    Image(systemName: "checkmark.seal")
                        .accessibilityLabel("已购买")
                case .available:
                    Label("可阅读", systemImage: "lock.open")
                        .accessibilityLabel("当前账号可阅读")
                case .notPurchased:
                    Image(systemName: "lock")
                        .accessibilityLabel("当前账号未购买")
                case .requiresPurchase:
                    Image(systemName: "lock")
                        .accessibilityLabel("当前账号需订阅本章")
                case .unknown:
                    Text("VIP")
                        .accessibilityLabel("付费章节，购买状态暂未确认")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("chapter-purchase-\(chapter.id)")
        }
    }
}
