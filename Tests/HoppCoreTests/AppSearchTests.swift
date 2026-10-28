import XCTest
@testable import HoppCore

final class AppSearchTests: XCTestCase {
    private let apps = [
        AppEntry(path: "/Applications/Safari Technology Preview.app", name: "Safari Technology Preview"),
        AppEntry(path: "/Applications/Safari.app", name: "Safari"),
        AppEntry(path: "/System/Applications/Calculator.app", name: "计算器", alternateName: "Calculator"),
        AppEntry(path: "/Applications/WeChat.app", name: "微信", alternateName: "WeChat")
    ]

    func testEmptyQueryKeepsCatalogOrder() {
        XCTAssertEqual(AppSearch.filter(apps, query: "  ").map(\.app), apps)
    }

    func testExactNameRanksAheadOfPrefix() {
        XCTAssertEqual(AppSearch.filter(apps, query: "safari").map(\.app.name),
                       ["Safari", "Safari Technology Preview"])
    }

    func testAlternateNameMatchesWithoutHighlight() throws {
        let match = try XCTUnwrap(AppSearch.filter(apps, query: "calc").first)
        XCTAssertEqual(match.app.name, "计算器")
        XCTAssertTrue(match.nameRanges.isEmpty)
    }

    func testPinyinMatchesLocalizedName() throws {
        let match = try XCTUnwrap(AppSearch.filter(apps, query: "weixin").first)
        XCTAssertEqual(match.app.name, "微信")
        XCTAssertEqual(match.nameRanges, [NSRange(location: 0, length: 2)])
        XCTAssertEqual(AppSearch.filter(apps, query: "jisuan").map(\.app.alternateName), ["Calculator"])
    }

    func testEveryTokenMustMatch() {
        XCTAssertEqual(AppSearch.filter(apps, query: "safari tech").map(\.app.name), ["Safari Technology Preview"])
        XCTAssertTrue(AppSearch.filter(apps, query: "safari missing").isEmpty)
    }
}
