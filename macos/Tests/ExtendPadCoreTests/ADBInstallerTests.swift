import XCTest
@testable import ExtendPadCore

final class ADBLookupTests: XCTestCase {
    func testSystemCopiesWinOverManagedCopy() {
        let list = ADB.candidatePaths(userPath: nil, env: ["ANDROID_HOME": "/sdk"], home: "/Users/x",
                                      bundled: nil, managed: "/managed/adb")
        XCTAssertEqual(list.first, "/sdk/platform-tools/adb")
        XCTAssertEqual(list.last, "/managed/adb", "ExtendPad's own copy is only a fallback")
        XCTAssertTrue(list.contains("/Users/x/Library/Android/sdk/platform-tools/adb"))
        XCTAssertTrue(list.contains("/opt/homebrew/bin/adb"))
    }

    func testUserPathFirstAndIgnoreSystem() {
        let list = ADB.candidatePaths(userPath: "~/tools/adb", env: ["ANDROID_HOME": "/sdk"], home: "/Users/x",
                                      bundled: nil, managed: "/managed/adb", ignoreSystem: true)
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].hasSuffix("/tools/adb"))
        XCTAssertFalse(list[0].hasPrefix("~"), "tilde is expanded")
        XCTAssertEqual(list[1], "/managed/adb")
    }
}

final class ADBInstallerTests: XCTestCase {
    private var sdkADB: String { FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Android/sdk/platform-tools/adb" }
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ep-adb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testGoogleSignedADBIsAccepted() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sdkADB), "no Android SDK adb on this machine")
        XCTAssertNoThrow(try ADBInstaller.verifyGoogleSignature(sdkADB))
    }

    func testAppleSignedBinaryIsRejected() {
        XCTAssertThrowsError(try ADBInstaller.verifyGoogleSignature("/bin/ls"), "signed, but not by Google's team")
    }

    func testUnsignedFakeIsRejected() throws {
        let fake = tmp.appendingPathComponent("adb")
        try "#!/bin/sh\necho 'Android Debug Bridge version 9.9.9'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertThrowsError(try ADBInstaller.verifyGoogleSignature(fake.path))
    }

    /// Full offline install path: unzip → signature → `adb version` → atomic swap.
    func testInstallArchiveWithRealADB() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sdkADB), "no Android SDK adb on this machine")
        let zip = try makeZip(adbFrom: sdkADB)
        let dest = tmp.appendingPathComponent("install/platform-tools")
        let version = try ADBInstaller(destination: dest).installArchive(zip)
        XCTAssertTrue(version.hasPrefix("Android Debug Bridge"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.appendingPathComponent("adb").path))
        // Re-installing replaces the copy cleanly.
        XCTAssertNoThrow(try ADBInstaller(destination: dest).installArchive(zip))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["platform-tools"], "no staging/old folders left behind")
    }

    func testRejectedArchiveLeavesExistingInstallUntouched() throws {
        let dest = tmp.appendingPathComponent("install/platform-tools")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let marker = dest.appendingPathComponent("adb")
        try "existing".write(to: marker, atomically: true, encoding: .utf8)
        let fakeDir = tmp.appendingPathComponent("fake")
        try FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
        let fake = fakeDir.appendingPathComponent("adb")
        try "#!/bin/sh\necho hi\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let zip = try makeZip(adbFrom: fake.path)
        XCTAssertThrowsError(try ADBInstaller(destination: dest).installArchive(zip)) { error in
            guard case ADBInstaller.InstallError.badSignature = error else { return XCTFail("expected badSignature, got \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "existing")
    }

    func testArchiveWithoutADBIsRejected() throws {
        let dir = tmp.appendingPathComponent("noadb/platform-tools")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("fastboot"), atomically: true, encoding: .utf8)
        let zip = tmp.appendingPathComponent("noadb.zip")
        XCTAssertEqual(ADBInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dir.path, zip.path], timeout: 30).status, 0)
        XCTAssertThrowsError(try ADBInstaller(destination: tmp.appendingPathComponent("d/platform-tools")).installArchive(zip)) { error in
            guard case ADBInstaller.InstallError.missingADB = error else { return XCTFail("expected missingADB, got \(error)") }
        }
    }

    /// Builds a zip shaped like Google's download: platform-tools/adb.
    private func makeZip(adbFrom path: String) throws -> URL {
        let root = tmp.appendingPathComponent("src-\(UUID().uuidString)/platform-tools")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: path, toPath: root.appendingPathComponent("adb").path)
        let zip = tmp.appendingPathComponent("pt-\(UUID().uuidString).zip")
        let r = ADBInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.path, zip.path], timeout: 30)
        XCTAssertEqual(r.status, 0, r.output)
        return zip
    }
}

/// The flow behind the "Install adb" button: no adb → adbMissing → install → monitor switches to the
/// managed copy without restarting the app.
final class ADBMissingToInstalledFlowTests: XCTestCase {
    func testMonitorPicksUpFreshlyInstalledADB() throws {
        let sdkADB = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Android/sdk/platform-tools/adb"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: sdkADB), "no Android SDK adb on this machine")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ep-flow-\(UUID().uuidString)")
        let dest = base.appendingPathComponent("platform-tools")
        setenv("EXTENDPAD_IGNORE_SYSTEM_ADB", "1", 1)
        setenv("EXTENDPAD_ADB_DIR", dest.path, 1)
        defer { unsetenv("EXTENDPAD_IGNORE_SYSTEM_ADB"); unsetenv("EXTENDPAD_ADB_DIR"); try? FileManager.default.removeItem(at: base) }

        let monitor = DeviceMonitor(port: 27_199)
        monitor.autoLaunchApp = false
        var phases: [DeviceSnapshot.Phase] = []
        var paths: [String?] = []
        let missing = expectation(description: "adbMissing")
        let found = expectation(description: "managed adb in use")
        var sawMissing = false, sawFound = false
        monitor.onUpdate = { snap in
            phases.append(snap.phase); paths.append(snap.adbPath)
            if snap.phase == .adbMissing, !sawMissing { sawMissing = true; missing.fulfill() }
            if snap.adbPath == dest.appendingPathComponent("adb").path, !sawFound { sawFound = true; found.fulfill() }
        }
        monitor.start()
        wait(for: [missing], timeout: 10)

        // Install a Google-signed adb into the managed location, as the button does after downloading.
        let src = base.appendingPathComponent("src/platform-tools")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: sdkADB, toPath: src.appendingPathComponent("adb").path)
        let zip = base.appendingPathComponent("pt.zip")
        XCTAssertEqual(ADBInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", src.path, zip.path], timeout: 30).status, 0)
        _ = try ADBInstaller(destination: dest).installArchive(zip)
        monitor.rescanADB()
        wait(for: [found], timeout: 15)
        monitor.stop()
        XCTAssertEqual(phases.first, .adbMissing)
        XCTAssertNotEqual(phases.last, .adbMissing, "after install the monitor no longer reports adb missing")
        XCTAssertTrue(ADB.isManaged(paths.last ?? nil))
    }
}
