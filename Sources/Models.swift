import Foundation

/// 正史里一条消息。字段全部可选——正史是活的，多一个键少一个键都不能让解码炸。
struct Msg: Decodable {
    var role: String = ""
    var content: String? = nil
    var ts: String? = nil
    var thinking: String? = nil
    var thinkSecs: Double? = nil
    var wake: Bool? = nil
    var toolCalls: [ToolCall]? = nil
    var images: [String]? = nil
    var meal: Bool? = nil
    var sleepNote: Bool? = nil
    var napNote: Bool? = nil
    var rainNote: Bool? = nil
    var knock: Bool? = nil
    var knockText: String? = nil
    var usage: Usage? = nil
    var interrupted: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case role, content, ts, thinking, wake, images, meal, knock, usage, interrupted
        case thinkSecs = "think_secs", toolCalls = "tool_calls", sleepNote = "sleep_note"
        case napNote = "nap_note", rainNote = "rain_note", knockText = "knock_text"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decode(String.self, forKey: .role)) ?? ""
        content = try? c.decode(String.self, forKey: .content)
        ts = try? c.decode(String.self, forKey: .ts)
        thinking = try? c.decode(String.self, forKey: .thinking)
        thinkSecs = try? c.decode(Double.self, forKey: .thinkSecs)
        wake = try? c.decode(Bool.self, forKey: .wake)
        toolCalls = try? c.decode([ToolCall].self, forKey: .toolCalls)
        images = try? c.decode([String].self, forKey: .images)
        meal = try? c.decode(Bool.self, forKey: .meal)
        sleepNote = try? c.decode(Bool.self, forKey: .sleepNote)
        napNote = try? c.decode(Bool.self, forKey: .napNote)
        rainNote = try? c.decode(Bool.self, forKey: .rainNote)
        knock = try? c.decode(Bool.self, forKey: .knock)
        knockText = try? c.decode(String.self, forKey: .knockText)
        usage = try? c.decode(Usage.self, forKey: .usage)
        interrupted = try? c.decode(Bool.self, forKey: .interrupted)
    }

    init(role: String, content: String?, ts: String?, images: [String]? = nil) {
        self.role = role; self.content = content; self.ts = ts; self.images = images
    }

    var isWake: Bool { wake == true }
    var isPing: Bool { meal == true || sleepNote == true || napNote == true || rainNote == true }
    var cleanThinking: String { (thinking ?? "").replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var date: Date? { ts.flatMap(TimeFmt.parse) }
    var localDay: String { date.map(TimeFmt.dayKey) ?? "" }
}

struct ToolCall: Decodable {
    struct Fn: Decodable { var name: String?; var arguments: String? }
    var function: Fn?
    var name: String { function?.name ?? "?" }
    var shortName: String { name.split(separator: "__").last.map(String.init) ?? name }
}

struct Usage: Decodable {
    var inputTokens: Int?
    var cachedTokens: Int?
    var outputTokens: Int?
    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", cachedTokens = "cached_tokens", outputTokens = "output_tokens"
    }
}

struct ConversationPayload: Decodable {
    var id: String
    var title: String?
    var messages: [Msg]
}

struct ConversationsPayload: Decodable {
    struct Item: Decodable { var id: String }
    var conversations: [Item]
}

struct Pulse: Decodable, Equatable {
    var n: Int
    var ts: String
}

enum TimeFmt {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let stampF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f
    }()
    private static let hmF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    static func parse(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
    static func dayKey(_ d: Date) -> String { day.string(from: d) }
    static func stamp(_ d: Date) -> String { stampF.string(from: d) }
    static func hm(_ d: Date) -> String { hmF.string(from: d) }
    static func stamp(_ iso: String?) -> String { iso.flatMap(parse).map(stamp) ?? "" }
    static func hm(_ iso: String?) -> String { iso.flatMap(parse).map(hm) ?? "" }
    static func nowIso() -> String { iso.string(from: Date()) }
}
