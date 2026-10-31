import Foundation

final class CodexRPC {
    private var process: Process?
    private var input: FileHandle?
    private let queue = DispatchQueue(label: "CodexMeter.rpc")
    private var buffer = Data()
    private var next = 0
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    var notification: ((String, [String: Any]) -> Void)?
    var disconnected: (() -> Void)?
    private var stopped = false
    func start(executable: URL, home: URL, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        stop(); stopped = false
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = executable; p.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = home.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env; p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        input = stdin.fileHandleForWriting; buffer = Data(); process = p
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in let data = handle.availableData; self?.queue.async { self?.receive(data) } }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] _ in self?.queue.async { guard let self = self, !self.stopped else { return }; self.failAll(); DispatchQueue.main.async { self.disconnected?() } } }
        do { try p.run(); call("initialize", ["clientInfo": ["name": "codex_meter_macos", "title": "CodexMeter", "version": appVersion]]) { [weak self] result in if case .success = result { self?.send(["method": "initialized", "params": [:]]) }; completion(result) } } catch { completion(.failure(error)) }
    }
    func call(_ method: String, _ params: [String: Any] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { self.next += 1; let id = self.next; self.pending[id] = completion; self.send(["id": id, "method": method, "params": params]); self.queue.asyncAfter(deadline: .now()+25) { if let callback = self.pending.removeValue(forKey: id) { DispatchQueue.main.async { callback(.failure(NSError(domain: "CodexMeter RPC timeout", code: 1))) } } } }
    }
    private func send(_ payload: [String: Any]) { guard let data = (jsonString(payload) + "\n").data(using: .utf8), let input = input else { return }; do { try input.write(contentsOf: data) } catch { queue.async { self.failAll() } } }
    private func receive(_ data: Data) { if data.isEmpty { return }; buffer.append(data); while let end = buffer.firstIndex(of: 10) { let line = Data(buffer[..<end]); buffer.removeSubrange(...end); guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }; if let id = object["id"] as? Int, let callback = pending.removeValue(forKey: id) { DispatchQueue.main.async { if let error = object["error"] as? [String: Any] { callback(.failure(NSError(domain: "CodexMeter", code: 1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Codex error"]))) } else { callback(.success(object["result"] as? [String: Any] ?? [:])) } } } else if let method = object["method"] as? String { DispatchQueue.main.async { self.notification?(method, object["params"] as? [String: Any] ?? [:]) } } } }
    private func failAll() { let callbacks = pending.values; pending.removeAll(); for callback in callbacks { DispatchQueue.main.async { callback(.failure(NSError(domain: "CodexMeter disconnected", code: 1))) } } }
    func stop() { stopped = true; if let p = process { p.terminationHandler = nil; (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil; (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil; if p.isRunning { p.terminate() } }; process = nil; input = nil; queue.async { self.failAll() } }
    static func find(preferred: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [preferred, "/Applications/Codex.app/Contents/Resources/codex", home+"/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home+"/.local/bin/codex", home+"/.npm-global/bin/codex"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0)+"/codex" }
        let bin = URL(fileURLWithPath: home+"/Library/Application Support/OpenAI/Codex/bin")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil) { paths += dirs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).map { $0.appendingPathComponent("codex").path } }
        return paths.first(where: { !$0.isEmpty && $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}
