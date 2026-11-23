import Foundation
import ExtendPadCore

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            SelfTest.run(arguments: args)
        }
        if args.contains("--install-adb") {
            installADB()
        }
        ExtendPadApp.main()
    }

    /// `ExtendPad --install-adb`: same download + Google-signature check as the menu button
    /// (destination overridable with EXTENDPAD_ADB_DIR). Exits 0 on success.
    static func installADB() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let installer = ADBInstaller()
        var lastPct = -1
        print("Downloading \(ADBInstaller.downloadURL.absoluteString)")
        installer.install(progress: { p in
            let pct = Int(p * 100)
            if pct / 10 != lastPct / 10 { print("  \(pct)%"); lastPct = pct }
        }, completion: { result in
            switch result {
            case .success(let v): print("Installed \(v) at \(ADB.managedPath)"); exit(0)
            case .failure(let e): print("Failed: \(e.localizedDescription)"); exit(1)
            }
        })
        dispatchMain()
    }
}
