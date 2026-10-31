import Foundation
import AppKit
import ImageIO

let appVersion = "4.0.0"
let repository = "AlexDM777/codex-meter"
let bundleIdentifier = "com.alexdm777.codexmeter"
let languageCodes = ["ru", "en", "de", "it", "es", "sr", "fr", "pt"]
struct Quota {
    let minutes: Int
    let remaining: Double
    let reset: Double
    var json: [String: Any] { ["minutes": minutes, "remaining": remaining, "reset": reset] }
    static func parse(_ value: Any?) -> Quota? {
        guard let m = value as? [String: Any], let number = m["usedPercent"] as? NSNumber, number.doubleValue.isFinite else { return nil }
        return Quota(minutes: (m["windowDurationMins"] as? NSNumber)?.intValue ?? 0, remaining: max(0, min(100, 100-number.doubleValue)), reset: (m["resetsAt"] as? NSNumber)?.doubleValue ?? 0)
    }
}
struct Usage {
    var windows: [Quota] = []
    var plan = ""
    var resets: Int? = nil
    var json: [String: Any] { ["windows": windows.map(\.json), "plan": planLabel, "resets": resets.map { $0 as Any } ?? NSNull()] }
    var planLabel: String { switch plan.lowercased() { case "plus": return "PLUS"; case "prolite": return "PRO $100"; default: return plan.isEmpty ? "—" : plan.uppercased() } }
    static func parse(_ data: [String: Any]) -> Usage {
        let buckets = data["rateLimitsByLimitId"] as? [String: Any]
        var bucket = buckets?["codex"] as? [String: Any]
        if bucket == nil, let old = data["rateLimits"] as? [String: Any], old["limitId"] == nil || (old["limitId"] as? String) == "codex" { bucket = old }
        let credits = data["rateLimitResetCredits"] as? [String: Any]
        return Usage(windows: [Quota.parse(bucket?["primary"]), Quota.parse(bucket?["secondary"])].compactMap { $0 }.sorted { $0.minutes < $1.minutes }, plan: bucket?["planType"] as? String ?? "", resets: (credits?["availableCount"] as? NSNumber)?.intValue)
    }
}
struct Theme {
    var values: [String: Any]
    var id: String { values["id"] as? String ?? "" }
    var custom = false
    var imageURL: URL
    var json: [String: Any] { var out = values; if custom, let d = try? Data(contentsOf: imageURL) { out["background"] = "data:image/\(imageURL.pathExtension.lowercased() == "png" ? "png" : "webp");base64," + d.base64EncodedString() } else { out["background"] = "skins/" + imageURL.lastPathComponent }; return out }
}
final class Library {
    let root: URL
    let profile: URL
    var themes: [Theme] = []
    var strings: [String: [String]] = [:]
    var errors: [String] = []
    init(root: URL, profile: URL) throws { self.root = root; self.profile = profile; strings = (try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("strings.json")))) as? [String: [String]] ?? [:]; try reload() }
    func reload() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("skins/skins.json"))) as? [String: Any]
        themes = (manifest?["skins"] as? [[String: Any]] ?? []).map { Theme(values: $0, imageURL: root.appendingPathComponent("skins/" + ($0["background"] as? String ?? ""))) }
        guard themes.count == 16 else { throw NSError(domain: "CodexMeter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing built-in skins"]) }
        errors = []
        let folder = profile.appendingPathComponent("UserSkins", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var next = 17
        for dir in (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !dir.lastPathComponent.hasPrefix(".") {
            do { var theme = try readCustom(dir.appendingPathComponent("skin.json")); theme.values["number"] = next; next += 1; themes.append(theme) } catch { errors.append(dir.lastPathComponent + ": " + error.localizedDescription) }
        }
    }
    func readCustom(_ url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        guard data.count <= 65536, var m = try JSONSerialization.jsonObject(with: data) as? [String: Any], m["format"] as? String == "codexmeter-skin-v1", let id = m["id"] as? String, id.range(of: "^[a-z0-9][a-z0-9-]{0,47}$", options: .regularExpression) != nil, let name = m["name"] as? String, !name.isEmpty, name.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), let filename = m["background"] as? String, ["background.webp", "background.png"].contains(filename), m["dark"] is Bool else { throw invalidSkin() }
        for key in ["ink", "fill", "accent"] { guard let c = m[key] as? String, c.range(of: "^#[a-fA-F0-9]{6}$", options: .regularExpression) != nil else { throw invalidSkin() } }
        let font = m["font"] as? String ?? "digital"
        guard ["digital", "sans", "serif", "mono"].contains(font) else { throw invalidSkin() }
        let image = url.deletingLastPathComponent().appendingPathComponent(filename)
        let bytes = try Data(contentsOf: image)
        guard bytes.count <= 20*1024*1024, let source = CGImageSourceCreateWithData(bytes as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w == h, (512...2048).contains(w) else { throw invalidSkin() }
        m["id"] = "user." + id; m["kind"] = "space"; m["font"] = font
        return Theme(values: m, custom: true, imageURL: image)
    }
    func invalidSkin() -> NSError { NSError(domain: "CodexMeter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid skin.json or background image. See SkinGuide.md."]) }
    func importSkin(_ url: URL) throws -> String {
        let theme = try readCustom(url)
        guard !themes.contains(where: { $0.id == theme.id }) else { throw invalidSkin() }
        let target = profile.appendingPathComponent("UserSkins/" + String(theme.id.dropFirst(5)), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw invalidSkin() }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        do { try FileManager.default.copyItem(at: url, to: target.appendingPathComponent("skin.json")); try FileManager.default.copyItem(at: theme.imageURL, to: target.appendingPathComponent(theme.imageURL.lastPathComponent)); try reload(); return theme.id } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
    func translate(_ key: String, _ lang: String) -> String { guard let i = languageCodes.firstIndex(of: lang), let row = strings[key], row.indices.contains(i) else { return key }; return row[i] }
}
func jsonString(_ value: Any) -> String { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{}" }; return text }
func coreTests() throws {
    let data: [String: Any] = ["rateLimitsByLimitId": ["codex": ["planType": "prolite", "primary": ["usedPercent": 17, "windowDurationMins": 300, "resetsAt": 1800000000], "secondary": ["usedPercent": 100, "windowDurationMins": 10080]]], "rateLimitResetCredits": ["availableCount": 2]]
    let value = Usage.parse(data)
    guard value.windows.count == 2, value.windows[0].remaining == 83, value.windows[1].remaining == 0, value.planLabel == "PRO $100", value.resets == 2, Usage.parse([:]).windows.isEmpty, Quota.parse(["usedPercent": -5])?.remaining == 100, Quota.parse(["usedPercent": 150])?.remaining == 0, Quota.parse([:]) == nil else { throw NSError(domain: "Tests", code: 1) }
    print("PASS: quota parsing, missing data, clamping, plan labels, reset credits")
}
