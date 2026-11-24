import AICleanerCore
import Foundation
import XCTest

final class CustomDirectoryStoreTests: XCTestCase {
    private var sandbox: TestSandbox!
    private var store: CustomDirectoryStore!

    override func setUpWithError() throws {
        sandbox = try TestSandbox(prefix: "CustomDirectoryStoreTests")
        let storageFile = sandbox.rootURL.appendingPathComponent("config/custom-dirs.json")
        let guardInstance = SafetyGuard(homeDirectory: sandbox.homeURL)
        store = CustomDirectoryStore(storageURL: storageFile, safetyGuard: guardInstance)
    }

    override func tearDown() {
        sandbox?.cleanup()
        sandbox = nil
        store = nil
    }

    func testAddPersistAndRemoveDoesNotTouchDiskFiles() throws {
        let dirURL = try sandbox.createDirectory(relativeToHome: "scratch-cache")
        let markerFile = try sandbox.createFile(relativeToHome: "scratch-cache/keep.tmp", byteCount: 512)

        let added = try store.add(url: dirURL, displayName: "自定义测试缓存", category: .cache, mode: .children)
        XCTAssertEqual(added.displayName, "自定义测试缓存")
        XCTAssertEqual(store.load().count, 1)
        XCTAssertEqual(store.load().first?.id, added.id)

        // 移除自定义目录仅修改配置列表，绝不删除磁盘目录或其中文件
        let remaining = try store.remove(id: added.id)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
    }

    func testRejectsMissingFileDuplicateAndProtectedPaths() throws {
        let validDir = try sandbox.createDirectory(relativeToHome: "valid-temp")
        let regularFile = try sandbox.createFile(relativeToHome: "just-a-file.txt", byteCount: 32)
        let missingDir = sandbox.homeURL.appendingPathComponent("not-found")
        let sshDir = try sandbox.createDirectory(relativeToHome: ".ssh")

        _ = try store.add(url: validDir)

        XCTAssertThrowsError(try store.add(url: validDir)) { error in
            XCTAssertEqual(error as? CustomDirectoryError, .duplicatePath(validDir.path))
        }

        XCTAssertThrowsError(try store.add(url: regularFile)) { error in
            XCTAssertEqual(error as? CustomDirectoryError, .notADirectory(regularFile.path))
        }

        XCTAssertThrowsError(try store.add(url: missingDir)) { error in
            XCTAssertEqual(error as? CustomDirectoryError, .directoryNotFound(missingDir.path))
        }

        XCTAssertThrowsError(try store.add(url: sshDir)) { error in
            guard case .protectedPath = error as? CustomDirectoryError else {
                return XCTFail("预期抛出 protectedPath 错误，实际为：\(error)")
            }
        }

        XCTAssertThrowsError(try store.add(url: sandbox.homeURL)) { error in
            guard case .protectedPath = error as? CustomDirectoryError else {
                return XCTFail("预期抛出 protectedPath 错误，实际为：\(error)")
            }
        }
    }
}
