import Foundation

/// 学编辑（09-15 寻定）：网关每天从她改字的记录攒一份纠错字典（/api/voice/fixes），松手那一刻先把腾讯识别的字按字典改一遍再给她看。
/// 每条带前后各一个字的上下文（空＝句首/句尾），只在同样的上下文里替换——单字替换不带上下文会把「可以」改成「克以」。
/// 字典存 UserDefaults，12 小时拉一次；拉不到就用上次的。
enum VoiceFixes {
    struct Fix: Codable { var l: String; var a: String; var r: String; var b: String; var n: Int }
    private struct Payload: Codable { var updated: String?; var fixes: [Fix] }
    private static let key = "voice.fixes"
    private static let atKey = "voice.fixes.at"
    private static var cached: [Fix]? = nil

    static var fixes: [Fix] {
        if let cached { return cached }
        let f = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }?.fixes ?? []
        cached = f
        return f
    }

    static func refresh() async {
        guard !Preview.on, Keychain.token != nil else { return }
        let at = UserDefaults.standard.double(forKey: atKey)
        guard Date().timeIntervalSince1970 - at > 12 * 3600 else { return }
        guard let data = try? await GatewayAPI.voiceFixes(), let p = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: atKey)
        cached = p.fixes
        PushRegistrar.diag("voice: fixes \(p.fixes.count)")
    }

    static func apply(_ s: String) -> String {
        var t = s
        for f in fixes where !f.a.isEmpty && !f.b.isEmpty {
            let left = f.l.isEmpty ? "^" : "(?<=" + NSRegularExpression.escapedPattern(for: f.l) + ")"
            let right = f.r.isEmpty ? "$" : "(?=" + NSRegularExpression.escapedPattern(for: f.r) + ")"
            guard let re = try? NSRegularExpression(pattern: left + NSRegularExpression.escapedPattern(for: f.a) + right) else { continue }
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length),
                                            withTemplate: NSRegularExpression.escapedTemplate(for: f.b))
        }
        return t
    }
}
