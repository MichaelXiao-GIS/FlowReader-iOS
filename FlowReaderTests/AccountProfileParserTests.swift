import XCTest
@testable import FlowReader

final class AccountProfileParserTests: XCTestCase {
    private let avatar = "https://avatar.sfacg.com/fixture-reader.jpg"

    func testAppUsesAndroidAccountAvatarFieldWithoutInventingFallbackFields() {
        XCTAssertEqual(AccountProfileParser.avatarURL(in: ["avatar": avatar])?.absoluteString, avatar)
        XCTAssertNil(AccountProfileParser.avatarURL(in: ["avatarImage": avatar, "url": avatar]))
        XCTAssertNil(AccountProfileParser.avatarURL(in: ["avatar": ["url": avatar]]))
    }

    func testAvatarNormalizesExistingRemoteURLFormatsWithoutChangingQuery() {
        let expected = "https://avatar.sfacg.com/fixture.jpg?width=160&quality=90"
        for source in [
            "  http://avatar.sfacg.com/fixture.jpg?width=160&quality=90\n",
            "//avatar.sfacg.com/fixture.jpg?width=160&amp;quality=90",
            #"https:\/\/avatar.sfacg.com\/fixture.jpg?width=160&quality=90"#,
            "HTTPS://avatar.sfacg.com/fixture.jpg?width=160&quality=90"
        ] {
            XCTAssertEqual(AccountProfileParser.avatarURL(source)?.absoluteString, expected)
        }
    }

    func testMissingMalformedAndNonRemoteAvatarsStayAbsent() {
        for value: Any in [NSNull(), 123, true, "", "  ", "/images/avatar.jpg", "file:///tmp/avatar.jpg",
                           "data:image/png;base64,AA", "https:///avatar.jpg", "https://user:pass@avatar.sfacg.com/a.jpg"] {
            XCTAssertNil(AccountProfileParser.avatarURL(in: ["avatar": value]))
        }
        XCTAssertNil(AccountProfileParser.avatarURL(in: [:]))
    }

    func testWebAliasesReuseSameURLNormalization() {
        for field in ["avatar", "userAvatar", "portrait", "headImg", "headimg"] {
            let response = "{login:true,\(field):'//avatar.sfacg.com/fixture-reader.jpg'}"
            XCTAssertEqual(AccountProfileParser.webAvatarURL(in: response)?.absoluteString, avatar)
        }
        XCTAssertNil(AccountProfileParser.webAvatarURL(in: "{login:true,name:'fixture-reader'}"))
    }

    func testWalletAndMemberProfilesPreserveSameAvatarAndIdentity() throws {
        let user: [String: Any] = ["accountId": 42, "nickName": "原创测试读者", "userName": "fixture-reader", "avatar": avatar]
        let wallet = try AccountWalletParser.parse(user: user, money: [:], generation: UUID())
        let member = try MemberGiftProtocol.account(from: user)
        XCTAssertEqual(wallet.account, member)
        XCTAssertEqual(wallet.account.avatarURL?.absoluteString, avatar)
        XCTAssertEqual(wallet.account.id, 42)
        XCTAssertEqual(wallet.account.name, "原创测试读者")
        XCTAssertEqual(wallet.account.accountName, "fixture-reader")
    }

    func testAvatarDoesNotEstablishIdentityOrChangeMissingNameFallbacks() throws {
        let user: [String: Any] = ["accountId": 42, "avatar": avatar]
        let wallet = try AccountWalletParser.parse(user: user, money: [:], generation: UUID())
        let member = try MemberGiftProtocol.account(from: user)
        XCTAssertEqual(wallet.account, member)
        XCTAssertEqual(member.name, "菠萝包读者")
        XCTAssertEqual(member.accountName, "42")
        XCTAssertThrowsError(try AccountWalletParser.parse(user: ["avatar": avatar], money: [:], generation: UUID()))
        XCTAssertThrowsError(try MemberGiftProtocol.account(from: ["avatar": avatar]))
    }
}
