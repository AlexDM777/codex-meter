import Foundation
import AppKit

if CommandLine.arguments.contains("--self-test") {
    do { try coreTests(); let root = Bundle.main.resourceURL!; let temp = FileManager.default.temporaryDirectory.appendingPathComponent("CodexMeter-tests-"+UUID().uuidString); let library = try Library(root: root, profile: temp); guard library.themes.count == 16, library.strings.count > 50 else { throw NSError(domain: "Resources", code: 1) }; for theme in library.themes { guard NSImage(contentsOf: theme.imageURL) != nil else { throw NSError(domain: "WebP", code: 1) } }; print("PASS: 16 built-in WebP themes, language resources"); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--apply-update") { exit(MacUpdates.apply(CommandLine.arguments)) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MeterApp()
app.delegate = delegate
app.run()
