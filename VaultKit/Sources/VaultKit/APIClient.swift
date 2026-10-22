import Foundation

public struct APIError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { message }
    public var isUnauthorised: Bool { status == 401 }
}

/// Filters for `GET /models`. Field names match the server's query parameters.
public struct ModelQuery: Hashable, Sendable {
    public var q = ""
    public var categoryId: Int?
    public var tags: [String] = []
    public var statuses: [String] = []
    public var favourite = false
    public var flagged = false
    public var untriaged: Bool?
    public var trashed = false
    public var printerId: Int?
    public var collectionId: Int?
    public var exts: [String] = []
    public var minRating: Int?
    public var sort = "new"

    public init() {}

    var items: [URLQueryItem] {
        var out: [URLQueryItem] = []
        if !q.isEmpty { out.append(.init(name: "q", value: q)) }
        if let categoryId { out.append(.init(name: "category_id", value: String(categoryId))) }
        tags.forEach { out.append(.init(name: "tags", value: $0)) }
        statuses.forEach { out.append(.init(name: "status", value: $0)) }
        exts.forEach { out.append(.init(name: "ext", value: $0)) }
        if favourite { out.append(.init(name: "favourite", value: "true")) }
        if flagged { out.append(.init(name: "flagged", value: "true")) }
        if let untriaged { out.append(.init(name: "untriaged", value: String(untriaged))) }
        if trashed { out.append(.init(name: "trashed", value: "true")) }
        if let printerId { out.append(.init(name: "printer_id", value: String(printerId))) }
        if let collectionId { out.append(.init(name: "collection_id", value: String(collectionId))) }
        if let minRating { out.append(.init(name: "min_rating", value: String(minRating))) }
        if sort != "new" { out.append(.init(name: "sort", value: sort)) }
        return out
    }

    /// The filters as a smart collection query, in the same shape as the URL parameters.
    public var json: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for item in items {
            guard let v = item.value else { continue }
            if ["tags", "status", "ext"].contains(item.name) {
                if case .array(let a) = out[item.name] { out[item.name] = .array(a + [.string(v)]) } else { out[item.name] = .array([.string(v)]) }
            } else {
                out[item.name] = .string(v)
            }
        }
        return out
    }
}

public final class APIClient: Sendable {
    public let baseURL: URL
    public let token: String
    let session: URLSession

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = parseServerDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: auth

    /// Signs in and returns a long-lived device token.
    public static func login(server: URL, username: String, password: String, deviceName: String) async throws -> (String, VaultUser) {
        struct Body: Encodable { let username, password, deviceName: String }
        struct Out: Decodable { let user: VaultUser; let token: String }
        var req = URLRequest(url: server.appending(path: "api/v1/auth/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(Body(username: username, password: password, deviceName: deviceName))
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        let out = try decoder.decode(Out.self, from: data)
        return (out.token, out.user)
    }

    public func logout() async {
        _ = try? await send("auth/logout", method: "POST")
    }

    public func me() async throws -> VaultUser { try await get("auth/me") }

    // MARK: models

    public func models(_ query: ModelQuery, page: Int = 1, pageSize: Int = 100) async throws -> Page<ModelSummary> {
        try await get("models", query: query.items + [.init(name: "page", value: String(page)), .init(name: "page_size", value: String(pageSize))])
    }

    public func model(_ id: Int) async throws -> ModelDetail { try await get("models/\(id)") }

    @discardableResult
    public func patchModel(_ id: Int, _ body: [String: JSONValue]) async throws -> ModelDetail {
        try await decode(send("models/\(id)", method: "PATCH", json: body))
    }

    @discardableResult
    public func setMyState(_ id: Int, favourite: Bool? = nil, rating: Int? = nil, status: String? = nil) async throws -> MyState {
        var body: [String: JSONValue] = [:]
        if let favourite { body["favourite"] = .bool(favourite) }
        if let rating { body["rating"] = .number(Double(rating)) }
        if let status { body["status"] = .string(status) }
        return try await decode(send("models/\(id)/me", method: "PUT", json: body))
    }

    public func bulk(_ ids: [Int], _ body: [String: JSONValue]) async throws {
        var b = body
        b["ids"] = .array(ids.map { .number(Double($0)) })
        _ = try await send("models/bulk", method: "POST", json: b)
    }

    public func deleteModel(_ id: Int) async throws { _ = try await send("models/\(id)", method: "DELETE") }
    public func restoreModel(_ id: Int) async throws { _ = try await send("models/\(id)/restore", method: "POST") }

    public func addFlag(_ id: Int, kind: FlagKind, note: String) async throws {
        _ = try await send("models/\(id)/flags", method: "POST", json: ["kind": .string(kind.rawValue), "note": .string(note)])
    }

    public func resolveFlag(_ flagId: Int, resolved: Bool) async throws {
        _ = try await send("flags/\(flagId)", method: "PATCH", query: [.init(name: "resolved", value: String(resolved))])
    }

    /// Removes the file from its model and from disk. Admins and the model's uploader only.
    public func deleteFile(_ id: Int) async throws { _ = try await send("files/\(id)", method: "DELETE") }

    // MARK: taxonomy

    public func categories() async throws -> [Category] { try await get("categories") }
    @discardableResult
    public func createCategory(name: String, parentId: Int?) async throws -> Category {
        try await decode(send("categories", method: "POST", json: ["name": .string(name), "parent_id": parentId.map { .number(Double($0)) } ?? .null]))
    }

    @discardableResult
    public func updateCategory(_ id: Int, name: String, parentId: Int?) async throws -> Category {
        try await decode(send("categories/\(id)", method: "PATCH", json: ["name": .string(name), "parent_id": parentId.map { .number(Double($0)) } ?? .null]))
    }

    /// Models and subcategories move up to the deleted category's parent.
    public func deleteCategory(_ id: Int) async throws { _ = try await send("categories/\(id)", method: "DELETE") }

    public func tags() async throws -> [Tag] { try await get("tags") }

    /// Renaming onto an existing tag merges the two.
    public func renameTag(_ id: Int, to name: String) async throws {
        _ = try await send("tags/\(id)", method: "PATCH", json: ["name": .string(name)])
    }

    public func deleteTag(_ id: Int) async throws { _ = try await send("tags/\(id)", method: "DELETE") }

    @discardableResult
    public func createCollection(name: String, smartQuery: [String: JSONValue]? = nil, shared: Bool = true) async throws -> VaultCollection {
        try await decode(send("collections", method: "POST", json: [
            "name": .string(name), "kind": .string(smartQuery == nil ? "manual" : "smart"),
            "query": .object(smartQuery ?? [:]), "shared": .bool(shared),
        ]))
    }

    public func updateCollection(_ c: VaultCollection, name: String, shared: Bool) async throws {
        _ = try await send("collections/\(c.id)", method: "PATCH", json: ["name": .string(name), "shared": .bool(shared), "query": .object(c.snakeCaseQuery)])
    }

    public func deleteCollection(_ id: Int) async throws { _ = try await send("collections/\(id)", method: "DELETE") }
    public func printers() async throws -> [Printer] { try await get("printers") }
    public func collections() async throws -> [VaultCollection] { try await get("collections") }
    public func stats() async throws -> Stats { try await get("stats") }

    // MARK: files

    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    /// Folder-safe name for this server. File and model ids are only unique per server, so
    /// anything cached by id must live under this name.
    public var cacheNamespace: String {
        var s = baseURL.absoluteString
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        return s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
    }

    public func thumbURL(_ fileId: Int) -> URL { url("files/\(fileId)/thumb", query: [.init(name: "v", value: String(fileId))]) }
    public func previewURL(_ fileId: Int, lod: Bool = false) -> URL {
        // v matches the server's LOD_VERSION so cached hover previews are refetched when it changes.
        url("files/\(fileId)/preview", query: lod ? [.init(name: "lod", value: "true"), .init(name: "v", value: "2")] : [])
    }
    public func fileDownloadURL(_ fileId: Int) -> URL { url("files/\(fileId)/download") }
    public func modelZipURL(_ modelId: Int) -> URL { url("models/\(modelId)/download") }

    public func data(from url: URL) async throws -> Data {
        let (data, resp) = try await session.data(for: authorised(URLRequest(url: url)))
        try Self.check(resp, data)
        return data
    }

    /// Download to `destination`, replacing any existing file.
    public func download(_ url: URL, to destination: URL) async throws {
        let (tmp, resp) = try await session.download(for: authorised(URLRequest(url: url)))
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError(status: http.statusCode, message: "Download failed (\(http.statusCode))")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
    }

    // MARK: uploads

    public func createBatch() async throws -> UploadBatch { try await decode(send("uploads", method: "POST")) }

    /// Upload files into a staged batch. `paths` are folder-relative paths ("" for loose files).
    public func uploadToBatch(_ batchId: String, files: [(url: URL, path: String)]) async throws -> UploadBatch {
        let body = try MultipartBody(files: files.map { ("files", $0.url) }, fields: files.map { ("paths", $0.path) })
        return try await decode(upload("uploads/\(batchId)/files", body: body))
    }

    public func commitBatch(_ batchId: String, groups: [CommitGroup]) async throws -> [Int] {
        struct Body: Encodable { let groups: [CommitGroup] }
        struct Out: Decodable { let modelIds: [Int] }
        let data = try await send("uploads/\(batchId)/commit", method: "POST", body: Self.encoder.encode(Body(groups: groups)))
        return try Self.decoder.decode(Out.self, from: data).modelIds
    }

    public func discardBatch(_ batchId: String) async throws { _ = try await send("uploads/\(batchId)", method: "DELETE") }

    public func addFiles(to modelId: Int, files: [URL], asPhotos: Bool = false) async throws -> ModelDetail {
        let fields = asPhotos ? [("photo", "true")] : []
        let body = try MultipartBody(files: files.map { ("files", $0) }, fields: fields)
        return try await decode(upload("models/\(modelId)/files", body: body))
    }

    // MARK: plumbing

    func authorised(_ req: URLRequest) -> URLRequest {
        var r = req
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await decode(send(path, query: query))
    }

    func decode<T: Decodable>(_ data: Data) throws -> T { try Self.decoder.decode(T.self, from: data) }

    func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], json: [String: JSONValue]? = nil, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(json)
        } else if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await session.data(for: authorised(req))
        try Self.check(resp, data)
        return data
    }

    func upload(_ path: String, body: MultipartBody) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3600
        defer { try? FileManager.default.removeItem(at: body.fileURL) }
        let (data, resp) = try await session.upload(for: authorised(req), fromFile: body.fileURL)
        try Self.check(resp, data)
        return data
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            struct Detail: Decodable { let detail: String }
            let msg = (try? JSONDecoder().decode(Detail.self, from: data).detail) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIError(status: http.statusCode, message: msg)
        }
    }
}

/// Server timestamps are naive UTC ISO strings, with or without microseconds.
func parseServerDate(_ s: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
        f.dateFormat = fmt
        if let d = f.date(from: s) { return d }
    }
    return ISO8601DateFormatter().date(from: s)
}
