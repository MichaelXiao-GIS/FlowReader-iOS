import Foundation
import CryptoKit
import Vision

/// Native SFACG client. Protocol endpoints informed by SFNovel-ReaderProject (GPL-3.0).
/// Public metadata uses an anonymous App request. Account content uses only Web cookies.
actor SFAPI {
    static let shared = SFAPI()
    private let session: URLSession
    private var webSession: WebSession?
    private var appSession: WebSession?
    private var deviceChannel = UserDefaults.standard.string(forKey: "sf.deviceChannel") ?? "VIVO"
    private var deviceOAID = UserDefaults.standard.string(forKey: "sf.deviceOAID") ?? ""
    private let deviceID: String
    private var lastRequest = Date.distantPast
    private let webAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: SFRedirectPolicy(), delegateQueue: nil)
        if let data = SessionVault.read() { webSession = try? JSONDecoder().decode(WebSession.self, from: data) }
        if let data = SessionVault.read(account: "sfacg-app") { appSession = try? JSONDecoder().decode(WebSession.self, from: data) }
        if let saved = UserDefaults.standard.string(forKey: "sf.installationID"), UUID(uuidString: saved) != nil {
            deviceID = saved.lowercased()
        } else {
            let generated = UUID().uuidString.lowercased()
            deviceID = generated
            UserDefaults.standard.set(generated, forKey: "sf.installationID")
        }
    }

    func hasSession() -> Bool { webSession?.isPresent == true || hasAppSession() }
    func hasAppSession() -> Bool { appSession?.isAppPresent == true }
    func hasWebSession() -> Bool { webSession?.isPresent == true }

    func importWebCookies(_ cookies: [HTTPCookie]) async throws -> AccountProfile {
        let candidate = WebSession(cookies: cookies)
        guard candidate.isPresent else { throw SFAPIError.loginRequired }
        let previous = webSession
        webSession = candidate
        do {
            let account = try await profile()
            try SessionVault.write(JSONEncoder().encode(candidate))
            return account
        } catch {
            webSession = previous
            throw error
        }
    }

    func logout() { webSession = nil; appSession = nil; SessionVault.clear(); SessionVault.clear(account: "sfacg-app") }

    func search(query: String, page: Int = 0) async throws -> [Book] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let payload = try await appData(path: "/search/novels/result/new", query: ["q": clean, "page": String(max(0, page)), "size": "24", "sort": "hot", "searchType": "0"])
        guard let object = payload as? [String: Any], let novels = object["novels"] as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        return novels.compactMap(Self.parseBook)
    }

    func discover() async throws -> [Book] {
        let payload = try await appData(path: "/novels/0/sysTags/novels", query: ["page": "0", "size": "18", "updatedays": "-1", "isfree": "both", "charcountbegin": "0", "systagids": "", "sort": "viewtimes", "isfinish": "both", "charcountend": "0"])
        guard let items = payload as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        return items.compactMap(Self.parseBook)
    }

    func detail(bookID: Int) async throws -> Book {
        guard bookID > 0 else { throw SFAPIError.invalidIdentifier }
        let payload = try await appData(path: "/novels/\(bookID)", query: ["expand": "chapterCount,bigNovelCover,typeName,intro,sysTags,latestchapter"])
        guard let object = payload as? [String: Any], let book = Self.parseBook(object) else { throw SFAPIError.invalidResponse }
        return book
    }

    func chapters(bookID: Int) async throws -> [Chapter] {
        guard bookID > 0 else { throw SFAPIError.invalidIdentifier }
        let payload = try await appData(path: "/novels/\(bookID)/dirs")
        guard let object = payload as? [String: Any], let volumes = (object["volumeList"] ?? object["volumes"]) as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        var chapters: [Chapter] = []
        var seen = Set<Int>()
        for volume in volumes {
            guard let volumeID = Self.integer(volume["volumeId"]), volumeID > 0 else { continue }
            for row in volume["chapterList"] as? [[String: Any]] ?? [] {
                guard let id = Self.integer(row["chapId"]), id > 0, seen.insert(id).inserted else { continue }
                let vip = row["isVip"] as? Bool ?? false
                chapters.append(Chapter(id: id, bookID: bookID, volumeID: volumeID, volumeTitle: volume["title"] as? String ?? "正文", title: row["ntitle"] as? String ?? row["title"] as? String ?? "章节 \(id)", order: chapters.count, isVIP: vip, isOwned: !vip))
            }
        }
        return chapters
    }

    func content(chapter: Chapter) async throws -> ChapterContent {
        guard chapter.id > 0, chapter.bookID > 0 else { throw SFAPIError.invalidIdentifier }
        if chapter.isVIP { return try await vipContent(chapter: chapter) }
        let html = try await webText(url: chapter.officialURL, referer: URL(string: "https://book.sfacg.com/Novel/\(chapter.bookID)/MainIndex/"))
        guard let text = HTMLParser.chapterBody(html), !text.contains("章节内容当前不可用") else { throw SFAPIError.emptyContent }
        if text.contains("请先订阅") || text.contains("本章需要订阅") { throw SFAPIError.subscriptionRequired }
        return ChapterContent(chapter: chapter, text: text)
    }

    /// The server decides whether a session owns the chapter. No purchase is issued.
    private func vipContent(chapter: Chapter) async throws -> ChapterContent {
        guard webSession?.isPresent == true else { throw SFAPIError.server("请先使用官方网页登录，再读取已订阅章节。") }
        let url = try Self.url("https://book.sfacg.com/ajax/ashx/common.ashx", query: ["op": "getChapPic", "tp": "true", "quick": "true", "cid": String(chapter.id), "nid": String(chapter.bookID), "font": "18", "lang": "", "w": "728"])
        var request = webRequest(url: url, referer: chapter.officialURL)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard response.mimeType?.hasPrefix("image/") == true, data.count > 512 else { throw SFAPIError.subscriptionRequired }
        let fingerprint = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard fingerprint != "412cee872b67ea5d6370e859686589c4" else { throw SFAPIError.subscriptionRequired }
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        recognition.usesLanguageCorrection = true
        try VNImageRequestHandler(data: data).perform([recognition])
        let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.isEmpty else { throw SFAPIError.emptyContent }
        if text.count < 500 && ["请先订阅", "订阅后", "订阅本章", "点击订阅", "请先登录", "购买本章", "尚未订阅"].contains(where: text.contains) { throw SFAPIError.subscriptionRequired }
        return ChapterContent(chapter: chapter, text: text)
    }

    func profile() async throws -> AccountProfile {
        if webSession?.isPresent != true, hasAppSession() { return try await appProfile() }
        guard webSession?.isPresent == true else { throw SFAPIError.loginRequired }
        let text = try await webText(url: URL(string: "https://passport.sfacg.com/Ajax/GetLoginInfo.ashx")!)
        guard HTMLParser.jsField("login", in: text) == "true" else { throw SFAPIError.loginRequired }
        let name = HTMLParser.jsField("nickname", in: text) ?? HTMLParser.jsField("nickName", in: text) ?? "菠萝包读者"
        let account = HTMLParser.jsField("name", in: text) ?? ""
        guard !account.isEmpty, account.count <= 80,
              account.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { throw SFAPIError.invalidResponse }
        let id = ["accountId", "accountid", "userId", "userid"].compactMap { HTMLParser.jsField($0, in: text).flatMap(Int.init) }.first ?? 0
        let avatar = ["avatar", "userAvatar", "portrait", "headImg", "headimg"].compactMap { HTMLParser.jsField($0, in: text).flatMap(Self.remoteURL) }.first
        return AccountProfile(id: id, name: name, accountName: account, avatarURL: avatar)
    }

    func bookshelf() async throws -> [Book] {
        if webSession?.isPresent != true, hasAppSession() { return try await appBookshelf() }
        let account = try await profile()
        let root = URL(string: "https://p.sfacg.com/u/\(account.accountName)/")!
        let html = try await webText(url: URL(string: "https://p.sfacg.com/u/content/\(account.accountName)-0-1")!, referer: root)
        var pockets: [(Int, String)] = []
        for item in HTMLParser.matches("href=['\"]/p/(\\d+)/['\"][^>]*>(.*?)</a>", in: html) {
            if let id = Int(item[1]), !pockets.contains(where: { $0.0 == id }) {
                pockets.append((id, HTMLParser.plainText(item[2])))
            }
        }
        var result: [Book] = []
        var seen = Set<Int>()
        for (pocketID, title) in pockets {
            let url = URL(string: "https://p.sfacg.com/p/\(pocketID)/")!
            let first = try await webText(url: url, referer: root)
            let pages = min(100, HTMLParser.matches("/p/\(pocketID)/(\\d+)/", in: first).compactMap { Int($0[1]) }.max() ?? 1)
            for page in 1...max(1, pages) {
                let source: String
                if page == 1 { source = first }
                else { source = try await webText(url: URL(string: "https://p.sfacg.com/p/\(pocketID)/\(page)/")!, referer: url) }
                for card in HTMLParser.matches("<ul\\b[^>]*>.*?</ul>", in: source) {
                    let markup = card[0]
                    guard let idString = HTMLParser.first("(?:https?:)?//book\\.sfacg\\.com/Novel/(\\d+)/", in: markup), let id = Int(idString), seen.insert(id).inserted else { continue }
                    guard let name = HTMLParser.first("<b>\\s*<a\\b[^>]*>(.*?)</a>", in: markup) else { continue }
                    let author = HTMLParser.first("作者[：:]\\s*(.*?)(?:</li>|<br|</div>)", in: markup).map(HTMLParser.plainText) ?? "未知作者"
                    let cover = HTMLParser.first("<img\\b[^>]*src=['\"]([^'\"]+)", in: markup).flatMap(Self.remoteURL)
                    result.append(Book(id: id, title: HTMLParser.plainText(name), author: author, coverURL: cover, shelfName: title))
                }
            }
        }
        return result
    }

    func audioTracks(bookID: Int) async throws -> [AudioTrack] {
        guard bookID > 0 else { throw SFAPIError.invalidIdentifier }
        let albumResponse = try await appData(path: "/albums/novelid/\(bookID)")
        let album = (albumResponse as? [String: Any]) ?? (albumResponse as? [[String: Any]])?.first
        guard let albumID = Self.integer(album?["albumId"]), albumID > 0 else { throw SFAPIError.noAudio }
        let volumeResponse = try await appData(path: "/albums/\(albumID)/volumes")
        let volumes = Self.objects(in: volumeResponse).filter { Self.integer($0["volumeId"]) != nil && Self.trackID($0) == nil }
        var tracks: [AudioTrack] = []
        var seen = Set<Int>()
        for volume in volumes {
            guard let volumeID = Self.integer(volume["volumeId"]) else { continue }
            let title = volume["title"] as? String ?? volume["volumeTitle"] as? String ?? "有声正文"
            let payload = try await appData(path: "/albumvolumes/\(volumeID)/chaps", query: ["expand": "fileName,audioUrl,needFireMoney,originNeedFireMoney,fileSize,duration"], includeSession: true)
            for row in Self.objects(in: payload) {
                guard let id = Self.trackID(row), seen.insert(id).inserted else { continue }
                let vip = (row["isVip"] as? Bool ?? false) || (Self.integer(row["needFireMoney"]) ?? 0) > 0
                tracks.append(AudioTrack(id: id, albumID: albumID, title: row["title"] as? String ?? row["ntitle"] as? String ?? row["chapterTitle"] as? String ?? "章节 \(id)", volumeTitle: title, order: tracks.count, duration: (row["duration"] as? NSNumber)?.doubleValue, isVIP: vip, sourceURL: Self.audioSource(row)))
            }
        }
        guard !tracks.isEmpty else { throw SFAPIError.noAudio }
        return tracks
    }

    func audioURL(track: AudioTrack) async throws -> URL {
        guard hasAppSession() else { throw SFAPIError.server("请在账号页连接有声服务后播放。") }
        if let url = track.sourceURL { return url }
        let payload = try await appData(path: "/albumchaps/\(track.id)", query: ["expand": "fileName,audioUrl,needFireMoney", "autoOrder": "false"], includeSession: true)
        guard let url = Self.objects(in: payload).compactMap(Self.audioSource).first else { throw track.isVIP ? SFAPIError.subscriptionRequired : SFAPIError.noAudio }
        return url
    }

    func audioRequest(track: AudioTrack) async throws -> URLRequest {
        let url = try await audioURL(track: track)
        var request = URLRequest(url: url)
        request.setValue("audio/mpeg,audio/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("https://book.sfacg.com/", forHTTPHeaderField: "Referer")
        request.setValue(appSession?.header(for: url), forHTTPHeaderField: "Cookie")
        return request
    }

    func loginApp(username: String, password: String) async throws -> AccountProfile {
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            throw SFAPIError.server("请输入账号和密码。")
        }
        deviceChannel = "VIVO"
        _ = try await appData(path: "/user/androiddeviceinfos", body: deviceBody(accountID: 0, full: true))
        if let device = try await appData(path: "/user/androiddeviceinfos", query: ["deviceId": deviceID, "package": "com.sfacg"]) as? [String: Any] {
            deviceChannel = device["initChannel"] as? String ?? "VIVO"
            deviceOAID = device["oaID"] as? String ?? ""
            UserDefaults.standard.set(deviceChannel, forKey: "sf.deviceChannel")
            UserDefaults.standard.set(deviceOAID, forKey: "sf.deviceOAID")
        }
        _ = try await appData(path: "/user/androiddeviceinfos", body: deviceBody(accountID: 0, full: true))
        _ = try await appData(path: "/user/androiddeviceinfos/conversions", body: conversionBody())
        let request = try appRequest(path: "/sessions", query: [:], body: ["username": username.trimmingCharacters(in: .whitespacesAndNewlines), "password": password, "shuMeiId": ""], includeSession: false)
        let (data, response) = try await send(request, acceptServerErrors: true)
        _ = try Self.parseAppResponse(data, response: response)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key] = String(describing: pair.value) }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!)
        let candidate = WebSession(cookies: cookies, app: true)
        guard candidate.isAppPresent else { throw SFAPIError.server("登录未返回有效会话，请在官方客户端完成账号验证后重试。") }
        let previous = appSession
        appSession = candidate
        do {
            let account = try await appProfile()
            _ = try await appData(path: "/user/androiddeviceinfos", body: deviceBody(accountID: account.id, full: false), includeSession: true)
            _ = try await appData(path: "/user/androiddeviceinfos/conversions", body: conversionBody(), includeSession: true)
            try SessionVault.write(JSONEncoder().encode(candidate), account: "sfacg-app")
            return account
        } catch {
            appSession = previous
            throw error
        }
    }

    private func appProfile() async throws -> AccountProfile {
        guard hasAppSession() else { throw SFAPIError.loginRequired }
        guard let user = try await appData(path: "/user", query: ["expand": "welfareCoin"], includeSession: true) as? [String: Any], let id = Self.integer(user["accountId"]), id > 0 else { throw SFAPIError.loginRequired }
        return AccountProfile(id: id, name: user["nickName"] as? String ?? "菠萝包读者", accountName: user["userName"] as? String ?? String(id), avatarURL: (user["avatar"] as? String).flatMap(Self.remoteURL))
    }

    private func appBookshelf() async throws -> [Book] {
        guard let pockets = try await appData(path: "/user/Pockets", query: ["expand": "novels"], includeSession: true) as? [[String: Any]] else { throw SFAPIError.invalidResponse }
        return pockets.flatMap { pocket -> [Book] in
            let expand = pocket["expand"] as? [String: Any] ?? [:]
            return (expand["novels"] as? [[String: Any]] ?? []).compactMap { row in
                guard var book = Self.parseBook(row) else { return nil }
                book.shelfName = pocket["name"] as? String
                return book
            }
        }
    }

    private func deviceBody(accountID: Int, full: Bool) -> [String: Any] {
        var body: [String: Any] = ["originUa": "Dalvik/2.1.0 (Linux; U; Android 16; V2238A Build/BP2A.250605.031.A3)", "accountId": accountID, "package": "com.sfacg", "webViewUA": "Mozilla/5.0 (Linux; Android 16; V2238A Build/BP2A.250605.031.A3; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/138.0.7204.179 Mobile Safari/537.36", "abi": "arm64-v8a", "deviceId": deviceID, "version": "5.2.84"]
        if full { body["manufacturer"] = "vivo"; body["pushInfo"] = [["channelName": "umeng"]] }
        if !deviceOAID.isEmpty { body["oaID"] = deviceOAID }
        return body
    }

    private func conversionBody() -> [String: Any] {
        let source = deviceBody(accountID: 0, full: false)
        var body: [String: Any] = ["originUA": source["originUa"]!, "webViewUA": source["webViewUA"]!, "action": "active"]
        if !deviceOAID.isEmpty { body["oaID"] = deviceOAID }
        return body
    }

    private func appRequest(path: String, query: [String: String], body: [String: Any]?, includeSession: Bool) throws -> URLRequest {
        let url = try Self.url("https://api.sfacg.com" + path, query: query)
        var request = URLRequest(url: url)
        let authorization = Data("androiduser:1a#$51-yt69;*Acv@qxq".utf8).base64EncodedString()
        request.setValue("Basic " + authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.sfacg.api+json;version=1", forHTTPHeaderField: "Accept")
        request.setValue("UTF-8", forHTTPHeaderField: "Accept-Charset")
        request.setValue("boluobao/5.2.84(android;36)/VIVO/\(deviceID)/\(deviceChannel)", forHTTPHeaderField: "User-Agent")
        request.setValue(try Self.securityHeader(deviceID: deviceID), forHTTPHeaderField: "SFSecurity")
        if includeSession { request.setValue(appSession?.header(for: url), forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func appData(path: String, query: [String: String] = [:], body: [String: Any]? = nil, includeSession: Bool = false) async throws -> Any {
        let request = try appRequest(path: path, query: query, body: body, includeSession: includeSession)
        let (data, response) = try await send(request, acceptServerErrors: true)
        return try Self.parseAppResponse(data, response: response)
    }

    static func parseAppResponse(_ data: Data, response: HTTPURLResponse) throws -> Any {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw SFAPIError.invalidResponse }
        let status = root["status"] as? [String: Any] ?? [:]
        let code = Self.integer(status["httpCode"]) ?? response.statusCode
        guard (200..<300).contains(code), (200..<300).contains(response.statusCode) else {
            if let message = status["msg"] as? String, !message.isEmpty { throw SFAPIError.server(message) }
            let failedCode = (200..<300).contains(response.statusCode) ? code : response.statusCode
            if failedCode == 401 || failedCode == 403 { throw SFAPIError.loginRequired }
            if failedCode == 429 { throw SFAPIError.server("请求较频繁，请稍后再试。") }
            throw SFAPIError.server("菠萝包服务暂时不可用（\(failedCode)）。")
        }
        return root["data"] ?? root
    }

    private func webRequest(url: URL, referer: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(webAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(referer?.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(webSession?.header(for: url), forHTTPHeaderField: "Cookie")
        return request
    }

    private func webText(url: URL, referer: URL? = nil) async throws -> String {
        let (data, _) = try await send(webRequest(url: url, referer: referer))
        guard let text = String(data: data, encoding: .utf8) else { throw SFAPIError.invalidResponse }
        return text
    }

    private func send(_ request: URLRequest, acceptServerErrors: Bool = false) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let now = Date()
        let wait = max(0, lastRequest.timeIntervalSince(now) + 0.3)
        // Reserve before awaiting to keep concurrent actor callers spaced apart.
        lastRequest = now.addingTimeInterval(wait)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SFAPIError.invalidResponse }
        if acceptServerErrors { return (data, http) }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401, 403: throw SFAPIError.loginRequired
        case 429: throw SFAPIError.server("请求较频繁，请稍后再试。")
        default: throw SFAPIError.server("菠萝包服务暂时不可用（\(http.statusCode)）。")
        }
    }

    private static func url(_ base: String, query: [String: String]) throws -> URL {
        guard var parts = URLComponents(string: base) else { throw SFAPIError.invalidResponse }
        if !query.isEmpty { parts.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw SFAPIError.invalidResponse }
        return url
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func remoteURL(_ source: String) -> URL? {
        let cleaned = HTMLParser.decodeEntities(source).replacingOccurrences(of: "\\/", with: "/")
        let absolute = cleaned.hasPrefix("//") ? "https:" + cleaned : cleaned
        guard var parts = URLComponents(string: absolute), let host = parts.host, !host.isEmpty,
              parts.scheme == "https" || parts.scheme == "http" else { return nil }
        if parts.scheme == "http" { parts.scheme = "https" }
        return parts.url
    }

    private static func parseBook(_ object: [String: Any]) -> Book? {
        guard let id = integer(object["novelId"]), id > 0, let title = object["novelName"] as? String else { return nil }
        let expand = object["expand"] as? [String: Any] ?? [:]
        let tags = (expand["sysTags"] as? [[String: Any]] ?? []).compactMap { $0["tagName"] as? String }
        let latest = (expand["latestChapter"] ?? expand["latestchapter"]) as? [String: Any]
        return Book(id: id, title: title, author: object["authorName"] as? String ?? "未知作者", coverURL: ((expand["bigNovelCover"] ?? object["novelCover"]) as? String).flatMap(remoteURL), summary: HTMLParser.plainText(expand["intro"] as? String ?? object["intro"] as? String ?? ""), category: expand["typeName"] as? String, tags: tags, isFinished: object["isFinish"] as? Bool ?? false, wordCount: integer(object["charCount"]), latestChapter: latest?["title"] as? String, updatedAt: object["lastUpdateTime"] as? String)
    }

    private static func objects(in payload: Any, depth: Int = 0) -> [[String: Any]] {
        guard depth < 10 else { return [] }
        if let list = payload as? [Any] { return list.flatMap { objects(in: $0, depth: depth + 1) } }
        guard let row = payload as? [String: Any] else { return [] }
        return [row] + ["data", "expand", "items", "list", "volumeList", "volumes", "chapterList", "chapters", "chaps", "chapList"].compactMap { row[$0] }.flatMap { objects(in: $0, depth: depth + 1) }
    }

    private static func trackID(_ row: [String: Any]) -> Int? {
        ["albumChapId", "chapterId", "audioId", "chapId", "id"].compactMap { integer(row[$0]) }.first(where: { $0 > 0 })
    }

    private static func audioSource(_ row: [String: Any]) -> URL? {
        ["fileName", "audioUrl", "audioURL", "mp3Url"].compactMap { (row[$0] as? String).flatMap(remoteURL) }.first
    }

    static func securityHeader(deviceID: String, nonce: String = UUID().uuidString, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> String {
        let nonce = nonce.uppercased()
        let stamp = String(timestamp)
        guard nonce.utf8.count == 36, deviceID.utf8.count == 36, UUID(uuidString: nonce) != nil, UUID(uuidString: deviceID) != nil, stamp.count == 13 else { throw SFAPIError.invalidIdentifier }
        let device = deviceID.uppercased()
        let repeated = Array(String(repeating: nonce, count: 4).utf8)
        var mask: [UInt8] = []
        for (index, length) in [13, 16, 36, 36].enumerated() {
            let start = Int(repeated[index + 1]) % 36
            mask += repeated[start..<(start + length)]
        }
        let source = Array((stamp + "lPQDb9AKO7$LjkPG" + device + nonce).utf8)
        let combined = zip(source, mask).map { UInt8((Int($0.0) + Int($0.1)) / 2) }
        let ordered = Array(combined[65...]) + Array(combined[..<13]) + Array(combined[29..<65]) + Array(combined[13..<29])
        let transformed = ordered.map { value -> UInt8 in
            if value < 48 { return value + 12 > 57 ? value + 19 : value + 12 }
            if (value > 57 && value < 65) || (value > 90 && value < 97) { return value + 19 }
            return value
        }
        let sign = Insecure.MD5.hash(data: Data(transformed)).map { String(format: "%02X", $0) }.joined()
        return "nonce=\(nonce)&timestamp=\(stamp)&devicetoken=\(device)&sign=\(sign)"
    }
}

/// Keep Web session headers inside the official HTTPS origin family on redirects.
private final class SFRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", let host = url.host?.lowercased(),
              host == "sfacg.com" || host.hasSuffix(".sfacg.com") else {
            completionHandler(nil)
            return
        }
        var safeRequest = request
        if response.url?.host?.lowercased() != host {
            safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(safeRequest)
    }
}
