import XCTest
@testable import Yggdrasil

@MainActor
final class CaptureFolderBindingTests: XCTestCase {
    private var defaults = UserDefaults.standard
    private var suiteName = ""

    override func setUp() {
        suiteName = "CaptureFolderBindingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        if !suiteName.isEmpty {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testBookmarkPersistsAndResolves() {
        let folder = URL(fileURLWithPath: "/private/capture")
        let bookmark = Data("capture-bookmark".utf8)
        let manager = makeManager(folder: folder, stale: false, bookmark: bookmark)

        manager.bind(folderURL: folder)
        XCTAssertEqual(defaults.data(forKey: CaptureFolderManager.bookmarkDefaultsKey), bookmark)

        let relaunchedManager = makeManager(folder: folder, stale: false, bookmark: bookmark)
        XCTAssertEqual(relaunchedManager.boundFolderURL, folder)
    }

    func testStaleBookmarkRefreshes() {
        let staleBookmark = Data("stale".utf8)
        let refreshedBookmark = Data("fresh".utf8)
        let folder = URL(fileURLWithPath: "/private/capture")
        defaults.set(staleBookmark, forKey: CaptureFolderManager.bookmarkDefaultsKey)

        let manager = CaptureFolderManager(
            defaults: defaults,
            resolveBookmark: { _ in ResolvedCaptureFolder(url: folder, isStale: true) },
            makeBookmark: { _ in refreshedBookmark },
            beginSecurityScope: { _ in true },
            endSecurityScope: { _ in }
        )

        XCTAssertEqual(manager.boundFolderURL, folder)
        XCTAssertEqual(defaults.data(forKey: CaptureFolderManager.bookmarkDefaultsKey), refreshedBookmark)
    }

    private func makeManager(folder: URL, stale: Bool, bookmark: Data) -> CaptureFolderManager {
        CaptureFolderManager(
            defaults: defaults,
            resolveBookmark: { _ in ResolvedCaptureFolder(url: folder, isStale: stale) },
            makeBookmark: { _ in bookmark },
            beginSecurityScope: { _ in true },
            endSecurityScope: { _ in }
        )
    }
}
