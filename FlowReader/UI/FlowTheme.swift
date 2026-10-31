import SwiftUI

enum FlowTheme {
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.08, green: 0.09, blue: 0.09, alpha: 1) : UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.13, green: 0.14, blue: 0.14, alpha: 1) : UIColor(red: 1, green: 0.99, blue: 0.97, alpha: 1) })
    static let ink = Color.primary
    static let accent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.93, green: 0.70, blue: 0.38, alpha: 1) : UIColor(red: 0.54, green: 0.32, blue: 0.12, alpha: 1) })
}

struct BookCover: View {
    let book: Book
    var width: CGFloat = 100
    var height: CGFloat = 140

    var body: some View {
        AsyncImage(url: book.coverURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(red: 0.25, green: 0.34, blue: 0.33), Color(red: 0.11, green: 0.20, blue: 0.21)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "sparkle")
                        .font(.system(size: width * 0.52, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.18))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(.white.opacity(0.5)).frame(width: 20, height: 1)
                        Text(book.title).font(.system(.headline, design: .serif)).lineLimit(4)
                            .foregroundStyle(.white)
                        Text(book.author).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    .padding(max(10, width * 0.12))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(.rect(cornerRadius: 7))
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 6).clipShape(.rect(cornerRadius: 3))
        }
        .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 5)
        .accessibilityHidden(true)
    }
}

struct BookRow: View {
    let book: Book
    var transition: Namespace.ID?

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if let transition {
                BookCover(book: book, width: 76, height: 108)
                    .matchedTransitionSource(id: book.id, in: transition)
            } else {
                BookCover(book: book, width: 76, height: 108)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(book.title).font(.headline).foregroundStyle(FlowTheme.ink).lineLimit(2)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !book.summary.isEmpty {
                    Text(book.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let category = book.category, !category.isEmpty { Text(category) }
                    if book.isFinished { Text("已完结") }
                }.font(.caption2).foregroundStyle(FlowTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct FlowErrorView: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        ContentUnavailableView {
            Label("暂时无法加载", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if let retry { Button("重试", action: retry).buttonStyle(.glass) }
        }
    }
}
