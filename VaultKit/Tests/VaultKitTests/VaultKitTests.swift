import XCTest
@testable import VaultKit

final class VaultKitTests: XCTestCase {
    func testGLBParses() throws {
        let url = Bundle.module.url(forResource: "sample", withExtension: "glb", subdirectory: "Fixtures")!
        let mesh = try GLBMesh(data: Data(contentsOf: url))
        XCTAssertGreaterThan(mesh.positions.count, 100)
        XCTAssertEqual(mesh.indices.count % 3, 0)
        XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.positions.count })
        let b = mesh.bounds
        XCTAssertGreaterThan(b.max.x - b.min.x, 10)
        XCTAssertNotNil(mesh.geometry().sources.first)
    }

    func testDecodesServerModel() throws {
        let json = """
        {"items":[{"id":3,"slug":"benchy","name":"Benchy","category_id":null,"tags":["boat"],"cover_file_id":6,
        "cover_has_preview":true,"preview_file_id":6,"untriaged":true,"size_x":38.0,"size_y":38.0,"size_z":8.0,
        "part_count":2,"tri_count":2060,"flag_count":0,"created_at":"2026-10-21T15:41:53.123456",
        "updated_at":"2026-10-21T15:41:53","deleted_at":null,"me":{"favourite":true,"rating":null,"status":"to_print"},
        "processing":false}],"total":1,"page":1,"page_size":60}
        """
        let page = try APIClient.decoder.decode(Page<ModelSummary>.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.first?.me.status, .toPrint)
        XCTAssertEqual(page.items.first?.dimensions, "38 × 38 × 8 mm")
    }

    func testQueryItems() {
        var q = ModelQuery()
        q.tags = ["a", "b"]
        q.untriaged = true
        let names = q.items.map(\.name)
        XCTAssertEqual(names.filter { $0 == "tags" }.count, 2)
        XCTAssertTrue(names.contains("untriaged"))
    }
}

final class FinishTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testSameDayShowsOnlyTheTime() {
        let s = formatFinishTime(date(4, 17, 42), from: date(4, 9), calendar: calendar)
        XCTAssertFalse(s.contains("tomorrow"))
        XCTAssertTrue(s.contains("42"), s)
    }

    func testNextDaySaysTomorrow() {
        let s = formatFinishTime(date(5, 7, 10), from: date(4, 23), calendar: calendar)
        XCTAssertTrue(s.hasSuffix("tomorrow"), s)
    }

    func testLaterShowsTheWeekday() {
        // 6 November 2026 is a Friday.
        let s = formatFinishTime(date(6, 7, 10), from: date(4, 9), calendar: calendar)
        XCTAssertTrue(s.hasSuffix("Fri"), s)
    }
}
