import Foundation
import AppKit

final class CodexRPC {
    private var process: Process?
    private var input: FileHandle?
    private let queue = DispatchQueue(label: "CodexMeter.rpc")
    private var buffer = Data(), diagnostics = Data()
    private var next = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private(set) var isConnected = false
    var notification: ((String, [String: Any]) -> Void)?
    var disconnected: ((Error) -> Void)?
    private func error(_ message: String) -> Error { NSError(domain: "CodexMeter", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func start(executable: URL, home: URL, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        isConnected = false
        queue.async {
            self.stopProcess()
            let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.executableURL = executable; p.arguments = ["app-server"]
            var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = home.path
            let binaryDirectory = executable.deletingLastPathComponent().path
            env["PATH"] = binaryDirectory+":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            p.environment = env; p.currentDirectoryURL = home
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
            self.input = stdin.fileHandleForWriting; self.buffer = Data(); self.diagnostics = Data(); self.process = p
            stdout.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
                let data = handle.availableData
                self?.queue.async { guard let self = self, let p = p, self.process === p else { return }; self.receive(data) }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
                let data = handle.availableData
                self?.queue.async { guard let self = self, let p = p, self.process === p else { return }; self.diagnostics.append(data); self.diagnostics = Data(self.diagnostics.suffix(2048)) }
            }
            p.terminationHandler = { [weak self] terminated in
                self?.queue.async {
                    guard let self = self, self.process === terminated else { return }
                    let detail = String(data: self.diagnostics, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let error = self.error("Codex exited (\(terminated.terminationStatus))." + (detail.isEmpty ? "" : "\n"+detail))
                    self.failAll(error); self.process = nil; self.input = nil
                    DispatchQueue.main.async { self.isConnected = false; self.disconnected?(error) }
                }
            }
            do {
                try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
                try p.run()
                self.request("initialize", ["clientInfo": ["name": "codex_meter_macos", "title": "CodexMeter", "version": appVersion]]) { result in
                    if case .success = result {
                        self.queue.async {
                            guard self.process === p, p.isRunning else { DispatchQueue.main.async { completion(.failure(self.error("Codex disconnected during initialization."))) }; return }
                            self.send(["method": "initialized", "params": [:]])
                            DispatchQueue.main.async { self.isConnected = true; completion(result) }
                        }
                    } else { completion(result) }
                }
            } catch { self.stopProcess(); DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func call(_ method: String, _ params: [String: Any] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async {
            guard self.process?.isRunning == true else { DispatchQueue.main.async { completion(.failure(self.error("Codex is not connected."))) }; return }
            self.request(method, params, completion: completion)
        }
    }
    private func request(_ method: String, _ params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        next += 1; let id = next; pending[id] = completion
        send(["id": id, "method": method, "params": params])
        queue.asyncAfter(deadline: .now()+25) {
            if let callback = self.pending.removeValue(forKey: id) { DispatchQueue.main.async { callback(.failure(self.error("Codex did not respond to \(method)."))) } }
        }
    }
    private func send(_ payload: [String: Any]) {
        guard let data = (jsonString(payload) + "\n").data(using: .utf8), let input = input else { return }
        do { try input.write(contentsOf: data) } catch { failAll(error) }
    }
    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }; buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let callback = pending.removeValue(forKey: id) {
                DispatchQueue.main.async {
                    if let error = object["error"] as? [String: Any] { callback(.failure(self.error(error["message"] as? String ?? "Codex error"))) }
                    else { callback(.success(object["result"] as? [String: Any] ?? [:])) }
                }
            } else if let method = object["method"] as? String {
                DispatchQueue.main.async { self.notification?(method, object["params"] as? [String: Any] ?? [:]) }
            }
        }
    }
    private func failAll(_ error: Error) { let callbacks = Array(pending.values); pending.removeAll(); for callback in callbacks { DispatchQueue.main.async { callback(.failure(error)) } } }
    private func stopProcess() {
        if let p = process {
            p.terminationHandler = nil
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil; input = nil; failAll(error("Codex connection was restarted."))
    }
    func stop() { isConnected = false; queue.async { self.stopProcess() } }
    static func executable(in url: URL) -> URL? {
        let path = url.path
        let target = path.hasSuffix(".app") ? url.appendingPathComponent("Contents/Resources/codex") : url
        return FileManager.default.isExecutableFile(atPath: target.path) && !target.hasDirectoryPath ? target : nil
    }
    static func find(preferred: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [preferred]
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") { paths.append(app.path) }
        paths += ["/Applications/Codex.app", home+"/Applications/Codex.app", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home+"/.local/bin/codex", home+"/.npm-global/bin/codex", home+"/.volta/bin/codex", home+"/Library/pnpm/codex"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0)+"/codex" }
        for base in [home+"/.nvm/versions/node", home+"/Library/Application Support/OpenAI/Codex/bin"] {
            if let dirs = try? FileManager.default.contentsOfDirectory(atPath: base) {
                let ordered = dirs.sorted { left, right in left.compare(right, options: .numeric) == .orderedDescending }
                for directory in ordered {
                    let folder = URL(fileURLWithPath: base).appendingPathComponent(directory)
                    paths.append(folder.appendingPathComponent("bin/codex").path)
                    paths.append(folder.appendingPathComponent("codex").path)
                }
            }
        }
        return paths.filter { $0.hasPrefix("/") }.compactMap { executable(in: URL(fileURLWithPath: $0)) }.first
    }
}
