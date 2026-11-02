import Foundation
import AppKit

if CommandLine.arguments.contains("--self-test") {
    do { try coreTests(); let root = Bundle.main.resourceURL!; let temp = FileManager.default.temporaryDirectory.appendingPathComponent("CodexMeter-tests-"+UUID().uuidString); let library = try Library(root: root, profile: temp); guard library.themes.count == 16, library.strings.count > 50 else { throw NSError(domain: "Resources", code: 1) }; for theme in library.themes { guard NSImage(contentsOf: theme.imageURL) != nil else { throw NSError(domain: "WebP", code: 1) } }; print("PASS: 16 built-in WebP themes, language resources"); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of: "--rpc-test"), CommandLine.arguments.count > index+1 {
    let executable = URL(fileURLWithPath: CommandLine.arguments[index+1])
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("CodexMeter RPC test "+UUID().uuidString)
    let rpc = CodexRPC()
    func fail(_ error: Error) { fputs("FAIL: \(error.localizedDescription)\n", stderr); rpc.stop(); exit(1) }
    func checkLogin(_ round: Int) {
        rpc.start(executable: executable, home: home) { result in
            switch result {
            case .failure(let error): fail(error)
            case .success:
                rpc.call("account/read", ["refreshToken": false]) { result in
                    if case .failure(let error) = result { fail(error); return }
                    rpc.call("account/login/start", ["type": "chatgpt"]) { result in
                        switch result {
                        case .failure(let error): fail(error)
                        case .success(let data):
                            guard let text = data["authUrl"] as? String, let url = URL(string: text), url.scheme == "https", let host = url.host, host == "chatgpt.com" || host.hasSuffix(".openai.com"), let loginID = data["loginId"] as? String else { fail(NSError(domain: "Missing browser sign-in URL", code: 1)); return }
                            rpc.call("account/login/cancel", ["loginId": loginID]) { result in
                                if case .failure(let error) = result { fail(error); return }
                                if round == 0 { rpc.stop(); checkLogin(1) }
                                else { print("PASS: real Codex initialize, account/read, browser login URL, cancel and reconnect; no personal credentials used"); rpc.stop(); exit(0) }
                            }
                        }
                    }
                }
            }
        }
    }
    checkLogin(0)
    DispatchQueue.main.asyncAfter(deadline: .now()+90) { fail(NSError(domain: "RPC test timed out", code: 1)) }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--apply-update") { exit(MacUpdates.apply(CommandLine.arguments)) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MeterApp()
app.delegate = delegate
app.run()
