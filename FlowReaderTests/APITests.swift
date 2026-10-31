import XCTest
@testable import FlowReader

final class APITests: XCTestCase {
    func testSecuritySignatureMatchesProtocolVector() throws {
        let header = try SFAPI.securityHeader(
            deviceID: "fedcba98-7654-3210-fedc-ba9876543210",
            nonce: "01234567-89ab-cdef-0123-456789abcdef",
            timestamp: 1_793_400_000_000
        )
        XCTAssertEqual(header, "nonce=01234567-89AB-CDEF-0123-456789ABCDEF&timestamp=1793400000000&devicetoken=FEDCBA98-7654-3210-FEDC-BA9876543210&sign=9664EE21604A7B5134BEBEB8CDB88750")
    }

    func testMalformedSignatureInputThrowsInsteadOfSlicingOutOfBounds() {
        XCTAssertThrowsError(try SFAPI.securityHeader(deviceID: "invalid"))
        XCTAssertThrowsError(try SFAPI.securityHeader(deviceID: UUID().uuidString, nonce: "bad"))
        XCTAssertThrowsError(try SFAPI.securityHeader(deviceID: UUID().uuidString, timestamp: 12))
    }

    func testWebAndAppSessionCookiesRemainIsolated() {
        let input = [cookie("session_PC"), cookie("session_APP"), cookie(".SFCommunity"), cookie("analytics"), cookie("session_PC", domain: ".evil-sfacg.com")]
        let web = WebSession(cookies: input)
        let app = WebSession(cookies: input, app: true)
        XCTAssertEqual(Set(web.cookies.map(\.name)), ["session_PC", ".SFCommunity"])
        XCTAssertEqual(Set(app.cookies.map(\.name)), ["session_APP", ".SFCommunity"])
        XCTAssertTrue(web.isPresent)
        XCTAssertFalse(web.isAppPresent)
        XCTAssertTrue(app.isAppPresent)
        XCTAssertFalse(app.isPresent)
    }

    func testSessionHeaderRequiresHTTPSAndExactDomainBoundary() {
        let session = WebSession(cookies: [cookie("session_PC")])
        XCTAssertNotNil(session.header(for: URL(string: "https://book.sfacg.com/Novel/1/")!))
        XCTAssertNil(session.header(for: URL(string: "http://book.sfacg.com/")!))
        XCTAssertNil(session.header(for: URL(string: "https://sfacg.com.evil.example/")!))
        XCTAssertNil(session.header(for: URL(string: "https://evil-sfacg.com/")!))
        let hostOnly = WebSession(cookies: [cookie("session_PC", domain: "passport.sfacg.com")])
        XCTAssertNil(hostOnly.header(for: URL(string: "https://book.sfacg.com/")!))
    }

    func testExpiredCookieAndUnrelatedPathAreExcluded() {
        let expired = WebSession(cookies: [cookie("session_PC", expires: Date(timeIntervalSinceNow: -60))])
        XCTAssertFalse(expired.isPresent)
        XCTAssertNil(expired.header(for: URL(string: "https://book.sfacg.com/")!))
        let scoped = WebSession(cookies: [cookie("session_PC", path: "/read")])
        XCTAssertNotNil(scoped.header(for: URL(string: "https://book.sfacg.com/read/chapter")!))
        XCTAssertNil(scoped.header(for: URL(string: "https://book.sfacg.com/reader")!))
    }

    func testChapterExtractionKeepsTextAndRemovesExecutableMarkup() {
        let html = "<header>不要读我</header><div id='ChapterBody'><p>甲&amp;乙</p><script>secret()</script><p>&#x4e19; &lt;标签&gt;</p></div><footer>不要读我</footer>"
        XCTAssertEqual(HTMLParser.chapterBody(html), "甲&乙\n丙 <标签>")
        XCTAssertNil(HTMLParser.chapterBody("<div>请登录</div>"))
        XCTAssertNil(HTMLParser.chapterBody("<div id='ChapterBody'> </div>"))
    }

    func testOfficialLoginLiteralParsingDoesNotRequireScriptExecution() {
        let body = "var info = {login:true, name:'reader_1', nickname:'读者', accountId:42};"
        XCTAssertEqual(HTMLParser.jsField("login", in: body), "true")
        XCTAssertEqual(HTMLParser.jsField("name", in: body), "reader_1")
        XCTAssertEqual(HTMLParser.jsField("nickname", in: body), "读者")
        XCTAssertEqual(HTMLParser.jsField("accountId", in: body), "42")
        XCTAssertNil(HTMLParser.jsField("missing", in: body))
    }

    func testAPIRejectionPreservesServerMessage() throws {
        let data = Data(#"{"status":{"httpCode":403,"msg":"请在官方客户端完成验证"},"data":null}"#.utf8)
        let response = HTTPURLResponse(url: URL(string: "https://api.sfacg.com/user")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try SFAPI.parseAppResponse(data, response: response)) { error in
            XCTAssertEqual(error.localizedDescription, "请在官方客户端完成验证")
            guard case SFAPIError.authenticationRequired = error else { return XCTFail("Authentication failures must remain identifiable") }
        }
    }

    func testTransportFailureAndMalformedJSONAreNotReportedAsSuccess() throws {
        let url = URL(string: "https://api.sfacg.com/novels/1")!
        let denied = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try SFAPI.parseAppResponse(Data(#"{"status":{"httpCode":200},"data":[]}"#.utf8), response: denied))
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try SFAPI.parseAppResponse(Data("<html>maintenance</html>".utf8), response: success))
        let parsed = try SFAPI.parseAppResponse(Data(#"{"status":{"httpCode":200},"data":{"novelId":42}}"#.utf8), response: success) as? [String: Any]
        XCTAssertEqual(parsed?["novelId"] as? Int, 42)
    }

    func testSuccessRequiresAnExplicitValidAPIEnvelope() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.sfacg.com/user/newSignInfo")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for text in [#"{}"#, #"{"data":[]}"#, #"{"status":{},"data":[]}"#,
                     #"{"status":{"httpCode":true},"data":[]}"#,
                     #"{"status":{"httpCode":200.5},"data":[]}"#,
                     #"{"status":{"httpCode":200,"errorCode":"invalid"},"data":[]}"#] {
            XCTAssertThrowsError(try SFAPI.parseAppResponse(Data(text.utf8), response: response), text)
        }
        for field in ["", ",\"errorCode\":200", ",\"errorCode\":0", ",\"errorCode\":null"] {
            let data = Data("{\"status\":{\"httpCode\":200\(field)},\"data\":{\"novelId\":42}}".utf8)
            let payload = try SFAPI.parseAppResponse(data, response: response) as? [String: Any]
            XCTAssertEqual(payload?["novelId"] as? Int, 42)
        }
    }

    func testBusinessRejectionCannotBecomeASignInReceipt() {
        let response = HTTPURLResponse(url: URL(string: "https://api.sfacg.com/user/newSignInfo")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for httpCode in ["", "\"httpCode\":200,"] {
            let body = Data("{\"status\":{\(httpCode)\"errorCode\":502,\"msg\":\"需要登录才能访问该资源\"},\"data\":null}".utf8)
            XCTAssertThrowsError(try SFAPI.parseAppResponse(body, response: response)) { error in
                guard case SFAPIError.authenticationRequired(let message) = error else { return XCTFail("Authentication must not become success") }
                XCTAssertEqual(message, "需要登录才能访问该资源")
            }
        }
        let risk = Data(#"{"status":{"httpCode":200,"errorCode":1146,"msg":"请先完成验证码"},"data":null}"#.utf8)
        XCTAssertThrowsError(try SFAPI.parseAppResponse(risk, response: response)) { error in
            XCTAssertEqual(error.localizedDescription, "请先完成验证码")
            XCTAssertFalse(SignInProtocol.isAlreadySignedError(error))
        }
    }

    private func cookie(_ name: String, domain: String = ".sfacg.com", path: String = "/", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "test-session", .domain: domain, .path: path, .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }
}
