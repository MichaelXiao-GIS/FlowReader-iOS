import SwiftUI

struct AccountAvatar: View {
    let profile: AccountProfile?
    let sessionGeneration: UUID?
    var loader: CoverThumbnailLoader = .shared
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .title3) private var diameter = 56.0
    @State private var loaded: LoadedAvatar?

    private struct Scope: Equatable {
        let profile: AccountProfile?
        let generation: UUID?
        let request: CoverThumbnailRequest?
    }

    private struct LoadedAvatar {
        let scope: Scope
        let thumbnail: CoverThumbnail
    }

    private var scope: Scope {
        Scope(profile: profile, generation: sessionGeneration,
              request: CoverThumbnailRequest(url: profile?.avatarURL, width: diameter, height: diameter, scale: displayScale))
    }

    private var visibleThumbnail: CoverThumbnail? {
        // Scope is checked while rendering, before the replacement request starts.
        // A reused account row can therefore never display the previous account's image.
        loaded?.scope == scope ? loaded?.thumbnail : nil
    }

    var body: some View {
        ZStack {
            Circle().fill(FlowTheme.accent.opacity(0.10))
            if let thumbnail = visibleThumbnail {
                Image(decorative: thumbnail.image, scale: displayScale, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: diameter * 0.46, weight: .regular))
                    .foregroundStyle(FlowTheme.accent)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("账号头像")
        .accessibilityValue(visibleThumbnail == nil ? "默认头像" : "头像已加载")
        .accessibilityIdentifier("account-avatar")
        .task(id: scope) {
            let target = scope
            guard loaded?.scope != target else { return }
            loaded = nil
            guard let request = target.request else { return }
            do {
                let thumbnail = try await loader.thumbnail(for: request)
                try Task.checkCancellation()
                loaded = LoadedAvatar(scope: target, thumbnail: thumbnail)
            } catch {
                // The same quiet placeholder covers missing, invalid and failed avatar URLs.
            }
        }
    }
}

#if DEBUG
/// Explicit offline UI coverage. No identity or image request reaches a live service.
enum AccountAvatarFixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--account-avatar-fixture")
    }

    static func profile(stage: Int) -> AccountProfile {
        switch stage {
        case 1:
            AccountProfile(id: -902, name: "无头像测试读者", accountName: "offline-avatar-empty")
        case 2:
            AccountProfile(id: -903, name: "头像加载失败测试读者", accountName: "offline-avatar-failure", avatarURL: URL(string: "https://avatar.invalid/failed.png"))
        default:
            AccountProfile(id: -901, name: "头像测试读者", accountName: "offline-avatar-loaded", avatarURL: URL(string: "https://avatar.invalid/original.png"))
        }
    }

    static let loader = CoverThumbnailLoader(operation: { request in
        guard request.url.lastPathComponent == "original.png",
              let context = CGContext(data: nil, width: 192, height: 192, bitsPerComponent: 8,
                                      bytesPerRow: 192 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CoverThumbnailError.unsupportedImage
        }
        // Original geometric portrait, rendered in memory only for this test fixture.
        context.setFillColor(CGColor(red: 0.12, green: 0.39, blue: 0.64, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 192, height: 192))
        context.setFillColor(CGColor(red: 0.72, green: 0.87, blue: 0.93, alpha: 1))
        context.fillEllipse(in: CGRect(x: 30, y: -44, width: 132, height: 132))
        context.setFillColor(CGColor(red: 1, green: 0.80, blue: 0.65, alpha: 1))
        context.fillEllipse(in: CGRect(x: 59, y: 82, width: 74, height: 74))
        guard let image = context.makeImage() else { throw CoverThumbnailError.unsupportedImage }
        return CoverThumbnail(image: image)
    })
}
#endif
