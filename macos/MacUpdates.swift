import Foundation
import AppKit
import CryptoKit
import Darwin

final class MacUpdates {
    var available: [String: Any]?
    var status = ""
    var busy = false
    var changed: (() -> Void)?
    let profile: URL
    init(profile: URL) { self.profile = profile }
    static func version(_ text: String) -> [Int]? { let s = text.hasPrefix("v") ? String(text.dropFirst()) : text; let bits = s.split(separator: "."); guard (2...4).contains(bits.count) else { return nil }; let numbers = bits.compactMap { Int($0) }; guard numbers.count == bits.count else { return nil }; return numbers + Array(repeating: 0, count: 4-numbers.count) }
    func check(completion: @escaping () -> Void) {
        guard !busy else { return }; busy = true; status = "Проверка обновлений…"; changed?()
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!); request.timeoutInterval = 20; request.setValue("CodexMeter-macOS/\(appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            var found: [String: Any]? = nil
            var message = "Не удалось проверить обновления"
            if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data, let release = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], release["draft"] as? Bool != true, release["prerelease"] as? Bool != true, let tag = release["tag_name"] as? String, let version = Self.version(tag), let current = Self.version(appVersion) {
                message = "Установлена последняя версия"
                if current.lexicographicallyPrecedes(version), let assets = release["assets"] as? [[String: Any]], let asset = assets.first(where: { $0["name"] as? String == "CodexMeter-macOS-universal.zip" }), let url = asset["browser_download_url"] as? String, url.hasPrefix("https://github.com/\(repository)/releases/download/"), let digest = asset["digest"] as? String, digest.range(of: "^sha256:[a-fA-F0-9]{64}$", options: .regularExpression) != nil { found = asset; found?["version"] = tag; message = "Доступно обновление" }
            }
            DispatchQueue.main.async { self.available = found; self.status = message; self.busy = false; self.changed?(); completion() }
        }.resume()
    }
    func install(completion: @escaping (Bool) -> Void) {
        guard !busy, let asset = available, let address = asset["browser_download_url"] as? String, let url = URL(string: address), let expected = asset["digest"] as? String, let size = asset["size"] as? Int, size > 0, size < 64*1024*1024 else { return }
        busy = true; status = "Скачивание обновления…"; changed?()
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        URLSession(configuration: config).downloadTask(with: url) { temp, response, error in
            do {
                guard error == nil, let temp = temp, (response as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: "Download", code: 1) }
                let bytes = try Data(contentsOf: temp)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                guard bytes.count == size, expected.lowercased() == "sha256:"+hash else { throw NSError(domain: "Checksum", code: 1) }
                let cache = self.profile.appendingPathComponent("Updates/"+UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let zip = cache.appendingPathComponent("update.zip"); try bytes.write(to: zip)
                let list = try Self.run("/usr/bin/unzip", ["-Z1", zip.path])
                guard list.split(separator: "\n").allSatisfy({ let p = String($0); return p.hasPrefix("CodexMeter.app/") && !p.split(separator: "/").contains("..") && !p.contains("\\") }) else { throw NSError(domain: "Archive", code: 1) }
                _ = try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, cache.path])
                let bundle = cache.appendingPathComponent("CodexMeter.app")
                guard let info = Bundle(url: bundle), info.bundleIdentifier == bundleIdentifier, Self.version(info.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") == Self.version(asset["version"] as? String ?? "") else { throw NSError(domain: "Bundle", code: 1) }
                _ = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
                let worker = cache.appendingPathComponent("CodexMeter-update-worker")
                guard let source = Bundle.main.executableURL else { throw NSError(domain: "Executable", code: 1) }
                try FileManager.default.copyItem(at: source, to: worker)
                let process = Process(); process.executableURL = worker; process.arguments = ["--apply-update", Bundle.main.bundleURL.path, bundle.path, String(ProcessInfo.processInfo.processIdentifier), self.profile.path]
                try process.run()
                DispatchQueue.main.async { completion(true) }
            } catch { DispatchQueue.main.async { self.status = "Не удалось обновить программу"; self.busy = false; self.changed?(); completion(false) } }
        }.resume()
    }
    static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.standardOutput = pipe; p.standardError = Pipe(); try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw NSError(domain: exe, code: Int(p.terminationStatus)) }; return String(data: data, encoding: .utf8) ?? ""
    }
    static func apply(_ args: [String]) -> Int32 {
        guard args.count == 6, let pid = Int32(args[4]) else { return 1 }
        let target = URL(fileURLWithPath: args[2]).standardizedFileURL, staged = URL(fileURLWithPath: args[3]).standardizedFileURL, profile = URL(fileURLWithPath: args[5])
        guard target.lastPathComponent == "CodexMeter.app", staged.lastPathComponent == "CodexMeter.app", Bundle(url: target)?.bundleIdentifier == bundleIdentifier, Bundle(url: staged)?.bundleIdentifier == bundleIdentifier, !target.resolvingSymlinksInPath().path.hasPrefix(staged.path) else { return 1 }
        let backup = target.deletingLastPathComponent().appendingPathComponent(".CodexMeter-backup-"+UUID().uuidString+".app")
        do {
            for _ in 0..<600 { if kill(pid, 0) != 0 { break }; Thread.sleep(forTimeInterval: 0.1) }
            guard kill(pid, 0) != 0 else { throw NSError(domain: "App still running", code: 1) }
            try FileManager.default.moveItem(at: target, to: backup)
            do { try FileManager.default.copyItem(at: staged, to: target); _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", target.path]) } catch { if FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.removeItem(at: target) }; try FileManager.default.moveItem(at: backup, to: target); throw error }
            _ = try run("/usr/bin/open", [target.path]); return 0
        } catch { try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true); try? Data("Update failed; old version preserved.".utf8).write(to: profile.appendingPathComponent("update-error.txt")); _ = try? run("/usr/bin/open", [target.path]); return 1 }
    }
}
