import Foundation
import ExtendPadCore

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run(arguments: CommandLine.arguments)
        }
        ExtendPadApp.main()
    }
}
