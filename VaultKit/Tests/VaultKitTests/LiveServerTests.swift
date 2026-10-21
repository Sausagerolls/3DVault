import XCTest
@testable import VaultKit

/// End-to-end tests against a running server. Skipped unless VAULT_TEST_SERVER,
/// VAULT_TEST_USER and VAULT_TEST_PASSWORD are set.
final class LiveServerTests: XCTestCase {
    var client: APIClient!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["VAULT_TEST_SERVER"].flatMap(URL.init(string:)), let user = env["VAULT_TEST_USER"], let pw = env["VAULT_TEST_PASSWORD"] else {
            throw XCTSkip("Set VAULT_TEST_SERVER / VAULT_TEST_USER / VAULT_TEST_PASSWORD to run live tests")
        }
        let (token, _) = try await APIClient.login(server: server, username: user, password: pw, deviceName: "VaultKit tests")
        client = APIClient(baseURL: server, token: token)
    }

    override func tearDown() async throws {
        await client?.logout()
    }

    func testBrowseAndPreview() async throws {
        let me = try await client.me()
        XCTAssertFalse(me.username.isEmpty)
        let page = try await client.models(ModelQuery())
        XCTAssertGreaterThan(page.total, 0)
        let m = try await client.model(page.items[0].id)
        XCTAssertFalse(m.files.isEmpty)
        if let cover = m.coverFileId {
            let data = try await client.data(from: client.thumbURL(cover))
            XCTAssertGreaterThan(data.count, 100)
        }
        let withPreview = page.items.first { $0.previewFileId != nil }!
        let glb = try await client.data(from: client.previewURL(withPreview.previewFileId!, lod: true))
        let mesh = try GLBMesh(data: glb)
        XCTAssertGreaterThan(mesh.indices.count, 0)
        _ = try await (client.categories(), client.tags(), client.printers(), client.collections(), client.stats())

        var q = ModelQuery()
        q.q = "benchy"
        let found = try await client.models(q)
        XCTAssertTrue(found.items.allSatisfy { $0.name.localizedCaseInsensitiveContains("benchy") })
    }

    func testEditStateAndDownload() async throws {
        let id = try await client.models(ModelQuery()).items[0].id
        let state = try await client.setMyState(id, favourite: true, rating: 4, status: PrintStatus.printed.rawValue)
        XCTAssertEqual(state.status, .printed)
        XCTAssertEqual(state.rating, 4)
        let m = try await client.patchModel(id, ["tags": .array([.string("from-mac")])])
        XCTAssertEqual(m.tags, ["from-mac"])
        try await client.bulk([id], ["remove_tags": .array([.string("from-mac")])])

        let f = m.files[0]
        let dest = FileManager.default.temporaryDirectory.appending(path: "vault-test/\(f.name)")
        try await client.download(client.fileDownloadURL(f.id), to: dest)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int), f.size)
    }

    func testUploadCommitAndTrash() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vault-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Minimal ASCII STL tetrahedron.
        let stl = """
        solid t
        facet normal 0 0 -1
        outer loop
        vertex 0 0 0
        vertex 10 0 0
        vertex 0 10 0
        endloop
        endfacet
        facet normal 0 -1 0
        outer loop
        vertex 0 0 0
        vertex 0 0 10
        vertex 10 0 0
        endloop
        endfacet
        facet normal -1 0 0
        outer loop
        vertex 0 0 0
        vertex 0 10 0
        vertex 0 0 10
        endloop
        endfacet
        facet normal 1 1 1
        outer loop
        vertex 10 0 0
        vertex 0 0 10
        vertex 0 10 0
        endloop
        endfacet
        endsolid t
        """
        let a = dir.appending(path: "mactest_\(UUID().uuidString.prefix(6))_body.stl")
        try stl.write(to: a, atomically: true, encoding: .utf8)
        let batch = try await client.createBatch()
        let staged = try await client.uploadToBatch(batch.id, files: [(a, "")])
        XCTAssertEqual(staged.files.count, 1)
        let ids = try await client.commitBatch(batch.id, groups: staged.groups.map { CommitGroup(name: "Mac test " + $0.name, fileIds: $0.fileIds) })
        XCTAssertEqual(ids.count, 1)
        let m = try await client.model(ids[0])
        XCTAssertEqual(m.files.count, 1)
        try await client.deleteModel(ids[0])
        let trashed = try await client.model(ids[0])
        XCTAssertNotNil(trashed.deletedAt)
    }

    func testOrganise() async throws {
        let suffix = UUID().uuidString.prefix(6)
        let parent = try await client.createCategory(name: "Mac cat \(suffix)", parentId: nil)
        let child = try await client.createCategory(name: "Child", parentId: parent.id)
        try await client.updateCategory(child.id, name: "Renamed", parentId: parent.id)
        let cats = try await client.categories()
        XCTAssertTrue(cats.contains { $0.id == child.id && $0.name == "Renamed" && $0.parentId == parent.id })
        try await client.deleteCategory(parent.id)
        let after = try await client.categories()
        XCTAssertNil(after.first { $0.id == child.id }?.parentId)
        try await client.deleteCategory(child.id)

        var q = ModelQuery()
        q.tags = ["a", "b"]
        q.printerId = 1
        q.q = "benchy"
        let smart = try await client.createCollection(name: "Smart \(suffix)", smartQuery: q.json)
        XCTAssertTrue(smart.isSmart)
        try await client.updateCollection(smart, name: "Smart renamed \(suffix)", shared: false)
        let saved = try await client.collections().first { $0.id == smart.id }!
        XCTAssertEqual(saved.name, "Smart renamed \(suffix)")
        XCTAssertFalse(saved.shared)
        XCTAssertEqual(saved.snakeCaseQuery["printer_id"], .string("1"))
        XCTAssertEqual(saved.snakeCaseQuery["tags"], .array([.string("a"), .string("b")]))
        try await client.deleteCollection(smart.id)

        let id = try await client.models(ModelQuery()).items[0].id
        let manual = try await client.createCollection(name: "Manual \(suffix)")
        try await client.bulk([id], ["add_to_collection": .number(Double(manual.id)), "add_tags": .array([.string("mactag\(suffix)")])])
        var inColl = ModelQuery()
        inColl.collectionId = manual.id
        let inside = try await client.models(inColl)
        XCTAssertEqual(inside.items.map(\.id), [id])
        try await client.deleteCollection(manual.id)

        let tag = try await client.tags().first { $0.name == "mactag\(suffix)".lowercased() }!
        try await client.renameTag(tag.id, to: "mactag-renamed\(suffix)")
        let renamed = try await client.tags().first { $0.name == "mactag-renamed\(suffix)".lowercased() }!
        try await client.deleteTag(renamed.id)
        let tags = try await client.tags()
        XCTAssertFalse(tags.contains { $0.id == renamed.id })
    }
}
