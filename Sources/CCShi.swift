import SwiftUI
import WebKit

/// 手机上的 CC师（10-27 寻定乙路线）：Keep → ke.seunk.cn/ccshi/…（Caddy 拿 App 口令问网关验过才放行）→ 反向隧道 → 腾讯机 ccx 小服务。
/// 后端源码在 vault `项目/脚本/腾讯机/ccshi/server.py`。多个会话；每个会话的事件按 seq 递增，断线凭最后的 seq 接上。
/// 克的字（Lora＋思源宋）只给克；CC师 的正文用圆体，一眼分得开。
/// 第二版（寻 10-27 点的单）：输入卡照搬克那边（语音、+ 菜单）、额度居中、小 Clawd 干活行（Clauding… 计时 · ↓token）、
/// thinking…/still thinking…/Thought for 2.3s、上下文＋压缩、问题卡、改文件红绿对比、任务清单、发图、递图/HTML 预览、
/// 长按复制/从这里重来、换模型、未读小红圈。

struct CCSession: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var updated: String?
    var status: String?
    var last_text: String?
    var archived: Bool?
    var unread: Int?
    var ctx: Int?
    var ctx_max: Int?          // 这个模型的窗口（CC 每轮报的 contextWindow；没报过按 20 万）
    var model: String?
    var model_actual: String?
    var seq: Int?
    var bg: [CCBgTask]?        // 后台还在跑的任务
    var running: Bool { status == "running" }
}

struct CCBgTask: Decodable, Hashable { var id: String?; var type: String?; var desc: String? }

struct CCEvent: Decodable {
    var seq: Int
    var ts: String?
    var kind: String
    var text: String?
    var name: String?
    var input: String?
    var id: String?          // tool / tool_result 的配对号
    var error: Bool?
    var secs: Double?
    var state: String?
    var images: [String]?
    var interject: Bool?
    var file: String?
    var type: String?
    var title: String?
    var pre: Int?
    var post: Int?
    var out: Int?
    // live（不落盘，SSE 顺带推）
    var verb: String?
    var started: Double?
    var doing: String?
    var since: Double?
    var now: Double?
    var tasks: [CCBgTask]?
    var status: String?        // bgdone：completed / failed …
    var desc: String?          // 正在跑的那条命令「在干嘛」
    var desc_tool: String?
    var thought: Double?       // 刚想完的那段秒数（亮几秒「thought for Xs」）
    var thought_at: Double?
    var ctx: Int?
}

struct CCUsage: Decodable {
    var five_hour: Double?
    var seven_day: Double?
    var seven_day_resets: Double?
    var line: String {
        guard let f = five_hour, let w = seven_day else { return "" }
        var s = "5h \(Int((f * 100).rounded()))% · week \(Int((w * 100).rounded()))%"
        if let r = seven_day_resets {
            let d = Date(timeIntervalSince1970: r)
            if Calendar.current.isDateInToday(d) { s += " · today" }
            else { let fm = DateFormatter(); fm.locale = Locale(identifier: "en_US"); fm.dateFormat = "EEE"; s += " · " + fm.string(from: d) }
        }
        return s
    }
}

enum CCShiAPI {
    static func url(_ path: String) -> URL {
        // 查询串不能拼进 path（appendingPathComponent 会把 ? 转成 %3F，构建 216 撞过）
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var comps = URLComponents(url: Gateway.home.appendingPathComponent("ccshi/api/" + parts[0]), resolvingAgainstBaseURL: false)!
        if parts.count > 1 { comps.percentEncodedQuery = parts[1] }
        return comps.url!
    }
    private static func req(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let token = Keychain.token else { throw GatewayAPI.Failure.unauthorized }
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        r.timeoutInterval = 20
        return r
    }
    static func get<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let (d, resp) = try await URLSession.shared.data(for: try req(path, method: method, body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw GatewayAPI.Failure.unauthorized }
        guard (200..<300).contains(code) else { throw GatewayAPI.Failure.http(code) }
        return try JSONDecoder().decode(T.self, from: d)
    }
    struct List: Decodable { var sessions: [CCSession] }
    struct Events: Decodable { var meta: CCSession; var events: [CCEvent] }
    struct Queued: Decodable { var queued: Int? }
    struct Unread: Decodable { var unread: Int }
    struct Uploaded: Decodable { var file: String }
    struct OK: Decodable { var ok: Bool? }

    static func sessions() async throws -> [CCSession] { (try await get("sessions") as List).sessions }
    static func usage() async -> CCUsage? { try? await get("usage") }
    static func unread() async -> Int? { (try? await get("unread") as Unread)?.unread }
    static func create(_ title: String) async throws -> CCSession { try await get("sessions", method: "POST", body: ["title": title]) }
    static func rename(_ id: String, _ title: String) async { _ = try? await get("sessions/\(id)/rename", method: "POST", body: ["title": title]) as CCSession }
    static func archive(_ id: String, _ on: Bool) async { _ = try? await get("sessions/\(id)/archive", method: "POST", body: ["archived": on]) as CCSession }
    static func send(_ id: String, _ text: String, images: [String] = []) async throws { _ = try await get("sessions/\(id)/send", method: "POST", body: ["text": text, "images": images]) as Queued }
    static func stop(_ id: String) async { _ = try? await get("sessions/\(id)/stop", method: "POST", body: [:]) as [String: Bool] }
    static func compact(_ id: String) async { _ = try? await get("sessions/\(id)/compact", method: "POST", body: [:]) as Queued }
    static func setModel(_ id: String, _ m: String) async -> CCSession? { try? await get("sessions/\(id)/model", method: "POST", body: ["model": m]) }
    static func rewind(_ id: String, seq: Int) async -> CCSession? { try? await get("sessions/\(id)/rewind", method: "POST", body: ["seq": seq]) }
    static func markRead(_ id: String, seq: Int) async { _ = try? await get("sessions/\(id)/read", method: "POST", body: ["seq": seq]) as OK }
    static func events(_ id: String, after: Int) async throws -> Events { try await get("sessions/\(id)/events?after=\(after)") }

    /// 她发的图：jpeg 字节直传，回服务端给的文件名
    static func upload(_ id: String, jpeg: Data) async throws -> String {
        guard let token = Keychain.token else { throw GatewayAPI.Failure.unauthorized }
        var r = URLRequest(url: url("sessions/\(id)/upload"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        r.httpBody = jpeg
        r.timeoutInterval = 60
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw GatewayAPI.Failure.http(0) }
        return try JSONDecoder().decode(Uploaded.self, from: d).file
    }

    /// 会话里的文件（她发的图、我递的图/HTML/PDF）：带口令取原始字节，内存里留一份
    @MainActor private static var cache: [String: Data] = [:]
    @MainActor static func file(_ sid: String, _ name: String) async -> Data? {
        let k = sid + "/" + name
        if let d = cache[k] { return d }
        if Preview.on {
            let r = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400))
            return r.image { c in UIColor(red: 0.85, green: 0.78, blue: 0.70, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 600, height: 400)) }.pngData()
        }
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: url("sessions/\(sid)/files/\(name)"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        cache[k] = d
        return d
    }

    /// SSE：吐 after 之后的事件（外加不落盘的 live 行），连着就一直等新的；断了由调用方凭最后 seq 重连
    static func stream(_ id: String, after: Int) -> AsyncThrowingStream<CCEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    guard let token = Keychain.token else { throw GatewayAPI.Failure.unauthorized }
                    var r = URLRequest(url: url("sessions/\(id)/stream?after=\(after)"))
                    r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    r.timeoutInterval = 60      // 服务端 20 秒一次心跳
                    let (bytes, resp) = try await URLSession.shared.bytes(for: r)
                    guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw GatewayAPI.Failure.http(0) }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                              let e = try? JSONDecoder().decode(CCEvent.self, from: d) else { continue }
                        c.yield(e)
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

extension Notification.Name {
    /// 点了「CC师」推送：object＝会话号（电脑上的会话是空串＝只开列表）
    static let keepOpenCCShi = Notification.Name("keep.openCCShi")
}

enum CCFmt {
    /// 43.2万 / 100万（小卡里用，紧凑）
    static func tokShort(_ n: Int) -> String {
        n >= 10000 ? (n % 10000 == 0 ? "\(n / 10000)万" : String(format: "%.1f万", Double(n) / 10000)) : String(n)
    }
    /// 4.2 万 / 1237
    static func tok(_ n: Int) -> String { n >= 10000 ? String(format: "%.1f 万", Double(n) / 10000) : String(n) }
    /// ↓5.7k（同 Claude Code 那行）
    static func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : String(n) }
    static func dur(_ s: Int) -> String { s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s" }
    /// 一轮收尾那行，照 Claude Code：「✻ Cooked for 43s · done 3:05 PM」（寻 10-27：token 数不放这儿，右上角有）
    static let doneVerbs = ["Baked", "Brewed", "Churned", "Cogitated", "Cooked", "Crunched", "Mulled", "Pondered",
                            "Simmered", "Noodled", "Percolated", "Sautéed", "Whisked", "Worked", "Marinated", "Kneaded"]
    static func endLine(_ e: CCEvent) -> String {
        let verb = doneVerbs[abs(e.seq) % doneVerbs.count]
        var t = "✻ " + verb + " for " + dur(Int(e.secs ?? 0))
        if let d = TimeFmt.parse(e.ts ?? "") {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US")
            f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "M/d h:mm a"
            t += " · done " + f.string(from: d)
        }
        return t
    }
    /// 干活行括号里那截：(1m 23s · ↓5.7k tokens)
    static func liveTail(_ el: Int, _ out: Int) -> String {
        var t = "(" + dur(el)
        if out > 0 { t += " · ↓" + k(out) + " tokens" }
        return t + ")"
    }
    static let models: [(String, String)] = [("", "默认"), ("claude-opus-5-5", "Opus 5.5"), ("claude-opus-4-6", "Opus 4.6"), ("claude-sonnet-5-5", "Sonnet 5.5")]
    static func modelShort(_ m: String?) -> String {
        guard let m, !m.isEmpty else { return "" }
        return models.first(where: { $0.0 == m })?.1 ?? m.replacingOccurrences(of: "claude-", with: "")
    }
}

// MARK: - 会话列表

@MainActor final class CCShiListModel: ObservableObject {
    @Published var sessions: [CCSession] = []
    @Published var usage = UserDefaults.standard.string(forKey: "cache.ccshiUsage") ?? ""
    @Published var err = ""
    @Published var showArchived = false

    func load() async {
        if Preview.on { loadPreview(); return }
        do { sessions = try await CCShiAPI.sessions(); err = "" }
        catch { err = "连不上 CC师（腾讯机小服务或隧道没起来）" }
        if let u = await CCShiAPI.usage(), !u.line.isEmpty { usage = u.line; UserDefaults.standard.set(usage, forKey: "cache.ccshiUsage") }
    }
    private func loadPreview() {
        guard let d = Preview.json("preview_ccshi"), let p = try? JSONDecoder().decode(CCShiPreview.self, from: d) else { return }
        sessions = p.sessions; usage = "5h 36% · week 6% · Sat"
    }
}

struct CCShiPreview: Decodable { var sessions: [CCSession]; var events: [CCEvent] }

struct CCShiListScreen: View {
    var onBack: () -> Void
    var onOpen: (String) -> Void
    var onFiles: () -> Void = {}
    @StateObject private var m = CCShiListModel()
    @State private var renaming: CCSession? = nil
    @State private var newTitle = ""
    private let tick = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onBack) { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
                    Text("CC师").font(Theme.round(14)).foregroundColor(Theme.muted)
                    Spacer()
                    Button(action: onFiles) {   // 文件：我的记忆、项目文档、给CC师读、临时给寻
                        Image("tool-archive").renderingMode(.template).resizable().frame(width: 19, height: 19).foregroundColor(Theme.text).frame(width: 34, height: 34)
                    }.buttonStyle(.plain)
                    Button { Task { await newSession() } } label: {
                        Text("+").font(Theme.ui(27, weight: .light)).foregroundColor(Theme.text).frame(width: 34, height: 34)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).frame(minHeight: 52)
                OrangeScroll(name: "ccshi") {
                    LazyVStack(spacing: 10) {
                        if !m.err.isEmpty {
                            Text(m.err).font(Theme.round(13)).foregroundColor(Theme.knockText).padding(.vertical, 20)
                        }
                        let live = m.sessions.filter { $0.archived != true }
                        let old = m.sessions.filter { $0.archived == true }
                        ForEach(live) { s in card(s) }
                        if live.isEmpty && m.err.isEmpty {
                            Text("还没有会话。点右上角 + 开一个。").font(Theme.round(13)).foregroundColor(Theme.muted).padding(.vertical, 30)
                        }
                        if !old.isEmpty {
                            Button { m.showArchived.toggle() } label: {
                                Text(m.showArchived ? "收起归档的 \(old.count) 个" : "归档的 \(old.count) 个")
                                    .font(Theme.round(12.5)).foregroundColor(Theme.muted).padding(.vertical, 10)
                            }.buttonStyle(.plain)
                            if m.showArchived { ForEach(old) { s in card(s) } }
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
                }
                // 额度一行：居中、钉在页底（寻 10-27：居中好看；同抽屉底那行）
                Text(m.usage).font(Theme.round(12)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity).frame(height: 16).padding(.top, 4).padding(.bottom, 10)
            }
        }
        .background(EdgeSwipe(onBack: onBack))
        .task { await m.load() }
        .onReceive(tick) { _ in if !Preview.on { Task { await m.load() } } }
        .alert("改名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("会话名", text: $newTitle)
            Button("好") { if let s = renaming { Task { await CCShiAPI.rename(s.id, newTitle); await m.load() } } }
            Button("取消", role: .cancel) {}
        }
    }

    private func card(_ s: CCSession) -> some View {
        Button { onOpen(s.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if s.running { Circle().fill(Theme.accent).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 } }
                    Text(s.title).font(Theme.cjk(15, weight: .medium)).foregroundColor(Theme.text).lineLimit(1)
                    Spacer()
                    Text(s.running ? "在干活" : TimeFmt.stamp(s.updated)).font(Theme.round(12)).foregroundColor(s.running ? Theme.accent : Theme.muted)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(s.last_text?.isEmpty == false ? s.last_text! : "（还没说话）")
                        .font(Theme.round(13)).foregroundColor(Theme.muted).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let n = s.unread, n > 0 { CCBadge(n: n) }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("改名") { newTitle = s.title; renaming = s }
            Button(s.archived == true ? "移出归档" : "归档") { Task { await CCShiAPI.archive(s.id, s.archived != true); await m.load() } }
        }
    }

    private func newSession() async {
        if Preview.on { return }
        let f = DateFormatter(); f.dateFormat = "M-d HH:mm"
        if let s = try? await CCShiAPI.create("新会话 " + f.string(from: Date())) { onOpen(s.id) }
    }
}

/// 未读小红圈：照抽屉留言板那枚（20 高、最小 20 宽、一位数正圆）
struct CCBadge: View {
    let n: Int
    var body: some View {
        Text("\(n)").font(Theme.round(12)).foregroundColor(.white)
            .padding(.horizontal, 6).frame(minWidth: 20).frame(height: 20)
            .background(Theme.accent, in: Capsule())
    }
}

// MARK: - 会话页

@MainActor final class CCShiSessionModel: ObservableObject {
    let id: String
    @Published var meta: CCSession? = nil
    @Published var events: [CCEvent] = []
    @Published var live: CCEvent? = nil
    @Published var liveOffset: Double = 0     // 服务端时钟 − 手机时钟（计时用服务端的起点）
    @Published var err = ""
    private(set) var last = 0
    private var streamTask: Task<Void, Never>? = nil
    var onNew: (() -> Void)? = nil
    init(id: String) { self.id = id }

    var running: Bool { meta?.running == true }

    func start() {
        if Preview.on { loadPreview(); return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let e = try await CCShiAPI.events(self.id, after: self.last)
                    self.meta = e.meta; self.absorb(e.events)
                    self.err = ""          // 接上了就收起「断线」——流一开就是一小时，不能等它结束才清
                    for try await ev in CCShiAPI.stream(self.id, after: self.last) { self.absorb([ev]) }
                    self.err = ""
                } catch {
                    if Task.isCancelled { return }
                    self.err = "断线了，正在重连…"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }
    func stopStream() { streamTask?.cancel(); streamTask = nil }

    private func absorb(_ evs: [CCEvent]) {
        var grew = false
        for e in evs {
            if e.kind == "live" {
                live = e
                if let n = e.now { liveOffset = n - Date().timeIntervalSince1970 }
                if let c = e.ctx { meta?.ctx = c }
                continue
            }
            guard e.seq > last else { continue }
            events.append(e); last = e.seq; grew = true
            if e.kind == "status" { meta?.status = e.state; if e.state == "idle" { live = nil } }
            if e.kind == "compact", let p = e.post { meta?.ctx = p }
            if e.kind == "bg" { meta?.bg = e.tasks ?? [] }
        }
        if grew { onNew?() }
    }

    func send(_ text: String, images: [Data] = []) async -> Bool {
        do {
            var names: [String] = []
            for d in images { names.append(try await CCShiAPI.upload(id, jpeg: d)) }
            try await CCShiAPI.send(id, text, images: names)
            err = ""; return true
        } catch { err = "没送出去，字留在输入框里"; return false }
    }
    func stop() { Task { await CCShiAPI.stop(id) } }
    func compact() { Task { await CCShiAPI.compact(id) } }
    func setModel(_ m: String) { Task { if let s = await CCShiAPI.setModel(id, m) { meta?.model = s.model } } }
    func markRead() { if !Preview.on, last > 0 { let s = last; Task { await CCShiAPI.markRead(id, seq: s) } } }

    private func loadPreview() {
        guard let d = Preview.json("preview_ccshi"), let p = try? JSONDecoder().decode(CCShiPreview.self, from: d) else { return }
        meta = p.sessions.first; events = p.events; last = p.events.last?.seq ?? 0
        if Preview.screen == "ccshirun" {
            meta?.status = "running"
            let now = Date().timeIntervalSince1970
            var lv = CCEvent(seq: 0, kind: "live")
            lv.verb = "Clauding"; lv.started = now - 83; lv.doing = "thinking"; lv.since = now - 12; lv.now = now; lv.out = 5700
            live = lv
        }
    }
}

/// 一轮里连着的东西排成「块」：她的话、我的思考、工具（调用＋结果配对）、正文、递来的文件、一轮收尾
private enum CCBlock: Identifiable {
    case user(CCEvent)
    case thinking(CCEvent)
    case tools([CCToolPair])
    case bgdone(CCEvent)
    case ask(CCEvent, Bool)
    case todo(CCEvent, Bool)
    case text(CCEvent)
    case show(CCEvent)
    case compact(CCEvent)
    case end(CCEvent)
    case error(CCEvent)
    var id: Int {
        switch self {
        case .user(let e), .thinking(let e), .text(let e), .show(let e), .compact(let e), .end(let e), .error(let e): return e.seq
        case .tools(let ps): return ps.first?.call.seq ?? 0
        case .bgdone(let e): return e.seq
        case .ask(let e, _), .todo(let e, _): return e.seq
        }
    }
    static let hidden: Set<String> = ["ToolSearch", "mcp__ccshi__show"]
    static func build(_ evs: [CCEvent]) -> [CCBlock] {
        var out: [CCBlock] = []
        var results: [String: CCEvent] = [:]
        for e in evs where e.kind == "tool_result" { if let i = e.id { results[i] = e } }
        let lastTodo = evs.last(where: { $0.kind == "tool" && $0.name == "TodoWrite" })?.seq
        let lastUser = evs.last(where: { $0.kind == "user" })?.seq ?? 0
        for e in evs {
            switch e.kind {
            case "user": out.append(.user(e))
            case "thinking": out.append(.thinking(e))
            case "tool":
                let n = e.name ?? ""
                if hidden.contains(n) { continue }
                if n.hasSuffix("__ask") { out.append(.ask(e, e.seq < lastUser)) }
                else if n == "TodoWrite" { out.append(.todo(e, e.seq == lastTodo)) }
                else {
                    let pair = CCToolPair(call: e, result: e.id.flatMap { results[$0] })
                    if case .tools(let ps)? = out.last { out[out.count - 1] = .tools(ps + [pair]) } else { out.append(.tools([pair])) }
                }
            case "text": out.append(.text(e))
            case "show": out.append(.show(e))
            case "compact": out.append(.compact(e))
            case "bgdone": out.append(.bgdone(e))
            case "result": out.append(.end(e))
            case "error": out.append(.error(e))
            default: break
            }
        }
        return out
    }
}

struct CCShiSessionScreen: View {
    var onBack: () -> Void
    var onOpen: (String) -> Void
    @StateObject private var m: CCShiSessionModel
    @State private var draft = ""
    @State private var focused = false
    @State private var pending: [UIImage] = []
    @State private var files: [String] = []        // 已传进 给CC师读/ 的文件（发的时候附在话末尾告诉我）
    @State private var uploading = 0
    @State private var plusOpen = false
    @State private var holdStarted = false
    @State private var webDoc: CCWebDoc? = nil
    @ObservedObject private var rec = VoiceRecorder.shared
    @Environment(\.scenePhase) private var phase

    init(id: String, onBack: @escaping () -> Void, onOpen: @escaping (String) -> Void = { _ in }) {
        self.onBack = onBack
        self.onOpen = onOpen
        _m = StateObject(wrappedValue: CCShiSessionModel(id: id))
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ZStack(alignment: .bottom) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(CCBlock.build(m.events)) { b in row(b) }
                                if m.running, let lv = m.live { CCLiveRow(live: lv, offset: m.liveOffset).padding(.top, 6).padding(.bottom, 4) }
                                Color.clear.frame(height: 8).id("bottom")
                            }
                            .padding(.horizontal, 18).padding(.top, 6)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: m.events.count) { _ in toBottom(proxy) }
                        .onChange(of: m.running) { _ in toBottom(proxy) }
                        .onAppear { toBottom(proxy) }
                    }
                    if rec.recording {
                        VStack(spacing: 0) {
                            LiveCard(rec: rec).padding(.bottom, 8)
                            HoldHints(rec: rec).padding(.bottom, 6)
                        }
                    }
                }
                if !m.err.isEmpty {
                    Text(m.err).font(Theme.round(12)).foregroundColor(Theme.knockText).padding(.bottom, 4)
                }
                composer
            }
        }
        .background(EdgeSwipe(onBack: onBack))
        .overlayPreferenceValue(PlusAnchorKey.self) { a in
            if plusOpen, let a {
                GeometryReader { g in
                    let r = g[a]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.15)) { plusOpen = false } }
                        plusMenu
                            .frame(width: 176, height: max(0, r.maxY - 4), alignment: .bottomLeading)
                            .offset(x: r.minX + 2)
                            .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .zIndex(50)
            }
        }
        .overlay(alignment: .topTrailing) {
            if infoOpen {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { withAnimation(.easeOut(duration: 0.15)) { infoOpen = false; modelOpen = false } }
                    HStack(alignment: .top, spacing: 8) {
                        if modelOpen { modelCard.padding(.top, 70).transition(.opacity) }
                        infoCard
                    }
                    .padding(.top, 52).padding(.trailing, 14)
                        .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        .sheet(item: $webDoc) { d in CCWebSheet(doc: d) }
        .onAppear {
            if Preview.on && ["ccshiinfo", "ccshimodel"].contains(Preview.screen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { infoOpen = true; modelOpen = Preview.screen == "ccshimodel" }
            }
        }
        .onAppear { let model = m; model.onNew = { [weak model] in model?.markRead() }; model.start() }
        .onDisappear { m.markRead(); m.stopStream() }
        .onChange(of: phase) { p in if p == .active { m.start() } }
        .onChange(of: focused) { on in if on { plusOpen = false } }
    }

    /// 钉底：懒列表头一回按估算高度定位，滚一次常停在半路（截图 435）——隔几拍再补两次
    private func toBottom(_ proxy: ScrollViewProxy) {
        if Preview.on && Preview.screen == "ccshitop" { return }
        for d in [0.05, 0.3, 0.8] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { proxy.scrollTo("bottom", anchor: .bottom) } }
    }

    // MARK: 顶栏：返回、会话名、模型；下面一行上下文（居中）＋压缩
    private var modelLabel: String {
        let a = CCFmt.modelShort(m.meta?.model)
        return a.isEmpty ? CCFmt.modelShort(m.meta?.model_actual) : a
    }
    @State private var infoOpen = false
    @State private var usageLine = ""
    private var ctxMax: Int { max(1, m.meta?.ctx_max ?? 200_000) }
    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
            Text(m.meta?.title ?? "CC师").font(Theme.round(14)).foregroundColor(Theme.muted).lineLimit(1)
            Spacer()
            Button { withAnimation(.easeOut(duration: 0.15)) { infoOpen.toggle() } } label: { CCRing(used: m.meta?.ctx ?? 0, max: ctxMax) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6).frame(minHeight: 44)
        .task { if let u = await CCShiAPI.usage() { usageLine = u.line } else if Preview.on { usageLine = "5h 36% · week 6% · Sat" } }
    }
    /// 点圆环出来的小卡：上下文、压缩、额度（寻 10-27：一行字＋按钮放顶上容易误点，收进圆环里）
    private var infoCard: some View {
        let c = m.meta?.ctx ?? 0
        let hot = Double(c) / Double(ctxMax) >= 0.75
        return VStack(alignment: .leading, spacing: 8) {
            // 上下文＋压缩同一行（寻 10-27：瘦长简洁，压缩别做成大块按钮）
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CCFmt.tokShort(c) + " / " + CCFmt.tokShort(ctxMax)).font(Theme.mono(13, weight: .medium))
                    .foregroundColor(hot ? CCRing.color(Double(c) / Double(ctxMax)) : Theme.text)
                Spacer(minLength: 6)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { infoOpen = false; modelOpen = false }
                    m.compact()
                } label: {
                    Text("压缩").font(Theme.round(12.5, weight: .medium)).foregroundColor(m.running ? Theme.muted : Theme.accent)
                }.buttonStyle(.plain).disabled(m.running)
            }
            if !usageLine.isEmpty { Text(usageLine).font(Theme.mono(11.5)).foregroundColor(Theme.muted) }
            Rectangle().fill(Theme.dyn(0x302D27, 0xFFFFFF).opacity(0.07)).frame(height: 1)
            // 在役模型；点开旁边弹小窗选别的
            Button { withAnimation(.easeOut(duration: 0.15)) { modelOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(modelLabel.isEmpty ? "模型" : modelLabel).font(Theme.mono(12.5)).foregroundColor(Theme.text)
                    Spacer(minLength: 4)
                    Image("chev").renderingMode(.template).resizable().frame(width: 12, height: 12)
                        .rotationEffect(.degrees(modelOpen ? -90 : 90)).foregroundColor(Theme.muted)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(width: 196)
        .background(Self.popBg)
        .shadow(color: .black.opacity(0.10), radius: 22, y: 8)
    }
    @State private var modelOpen = false
    /// 换模型的小窗（贴在小卡左边）：一行一个，当前那个打勾；换了从下一轮起生效
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CCFmt.models.filter { !$0.0.isEmpty }, id: \.0) { mm in
                let on = modelLabel == mm.1
                Button {
                    m.setModel(mm.0)
                    withAnimation(.easeOut(duration: 0.15)) { modelOpen = false }
                } label: {
                    HStack(spacing: 8) {
                        Text(mm.1).font(Theme.mono(12.5)).foregroundColor(Theme.text)
                        Spacer(minLength: 4)
                        if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accent) }
                    }
                    .padding(.horizontal, 14).frame(height: 38).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 150)
        .background(Self.popBg)
        .shadow(color: .black.opacity(0.10), radius: 22, y: 8)
    }
    private static var popBg: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bg.opacity(0.6)))
    }

    // MARK: 一块
    @ViewBuilder private func row(_ b: CCBlock) -> some View {
        switch b {
        case .user(let e):
            VStack(alignment: .trailing, spacing: 6) {
                if let imgs = e.images, !imgs.isEmpty {
                    HStack(spacing: 6) { ForEach(imgs, id: \.self) { n in CCFileImage(sid: m.id, name: n, maxW: 120, maxH: 120) } }
                }
                UserRowView(text: e.text ?? "", stamp: TimeFmt.stamp(e.ts), images: [], pick: e.interject == true ? "插话" : nil)   // 干活时发的话＝插进那一轮
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.vertical, 12)
        case .thinking(let e):
            ThinkView(text: e.text ?? "", label: e.secs.map { "Thought for \(String(format: "%.1f", $0))s" } ?? "Thought").padding(.vertical, 3)
        case .tools(let ps):
            CCToolGroup(pairs: ps).padding(.vertical, 3)
        case .bgdone(let e):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(e.status == "completed" ? Theme.dyn(0x7FA36B, 0x8DB57A) : Theme.knockText).frame(width: 7, height: 7)
                Text(e.text?.isEmpty == false ? e.text! : "Background command \"\(e.desc ?? "")\" \(e.status ?? "")")
                    .font(Theme.mono(12)).foregroundColor(Theme.text)
            }
            .padding(.vertical, 5)
        case .ask:
            EmptyView()   // 寻 10-27：问题卡长在输入卡上，流里那行多余；她的回答气泡就是痕迹
        case .todo(let e, let latest):
            CCTodoCard(event: e, open: latest).padding(.vertical, 6)
        case .text(let e):
            CCTextRow(event: e, onRewind: { Task { if let s = await CCShiAPI.rewind(m.id, seq: e.seq) { onOpen(s.id) } } })
        case .show(let e):
            CCShowCard(sid: m.id, event: e, onOpen: { webDoc = $0 }).padding(.vertical, 8)
        case .compact(let e):
            Text("上下文压缩过了：\(CCFmt.tok(e.pre ?? 0)) → \(CCFmt.tok(e.post ?? 0))")
                .font(Theme.round(12)).foregroundColor(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 10)
        case .end(let e):
            // 照 Claude Code：整行灰，✻ 也灰；✻ 单用系统字（Cascadia 没有这个字形，画成了 *，截图 452）
            (Text("✻ ").font(.system(size: 12.5, weight: .semibold)) + Text(String(CCFmt.endLine(e).dropFirst(2))).font(Theme.mono(12)))
                .foregroundColor(Theme.muted.opacity(0.85)).padding(.top, 2).padding(.bottom, 10)
        case .error(let e):
            Text(e.text ?? "出错了").font(Theme.round(13)).foregroundColor(Theme.knockText).padding(.vertical, 6)
        }
    }

    // MARK: 输入卡（照搬克那边：同一张卡、投影、长按说话、+ 菜单、↑/■/声波钮）
    private var canSend: Bool { uploading == 0 && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty || !files.isEmpty) }

    private var composer: some View {
        VStack(spacing: 6) {
            if let bg = m.meta?.bg, !bg.isEmpty { bgRow(bg) }
            if let a = activeAsk {
                CCAskPanel(qs: CCAsk.parse(a), step: $askStep, answers: $askAnswers, multi: $askMulti, onDone: { t in
                    askStep = 0; askAnswers = [:]; askMulti = []
                    Task { _ = await m.send(t) }
                })
            }
            if !files.isEmpty || uploading > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(files.enumerated()), id: \.offset) { i, f in
                            HStack(spacing: 6) {
                                Image("tool-notebook").renderingMode(.template).resizable().frame(width: 12, height: 12).foregroundColor(Theme.text)
                                Text((f as NSString).lastPathComponent).font(Theme.round(12.5)).foregroundColor(Theme.text).lineLimit(1)
                                Button { files.remove(at: i) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.muted).frame(width: 18, height: 18)
                                }.buttonStyle(.plain)
                            }
                            .padding(.leading, 10).padding(.trailing, 4).frame(height: 28)
                            .background(Theme.userBubble, in: Capsule())
                        }
                        if uploading > 0 { Text("上传中…").font(Theme.round(12)).foregroundColor(Theme.muted) }
                    }.padding(.top, 4)
                }
            }
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pending.enumerated()), id: \.offset) { i, img in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Button { pending.remove(at: i) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                        .frame(width: 18, height: 18).background(Color.black.opacity(0.55), in: Circle())
                                }.buttonStyle(.plain).offset(x: 4, y: -4)
                            }
                        }
                    }.padding(.horizontal, 2).padding(.top, 6)
                }
            }
            ZStack {
                Composer(text: $draft, focused: $focused, placeholder: activeAsk != nil ? "都不是？直接说…" : (m.running ? "插一句…" : "Chat with CC师…"))
                    .opacity(rec.recording ? 0 : 1)
                    .overlay {
                        if !focused && draft.isEmpty {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { focused = true }
                                .gesture(LongPressGesture(minimumDuration: 0.2).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                                    .onChanged { v in
                                        switch v {
                                        case .second(true, let drag):
                                            if !holdStarted { holdStarted = true; startHold() }
                                            let md = Self.holdMode(drag?.translation ?? .zero)
                                            let c = md == .cancel, e = md == .edit
                                            if rec.cancelHint != c || rec.editHint != e {
                                                rec.cancelHint = c; rec.editHint = e
                                                if c || e { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                                            }
                                        default: break
                                        }
                                    }
                                    .onEnded { v in
                                        holdStarted = false
                                        if case .second(true, let drag) = v { endHold(Self.holdMode(drag?.translation ?? .zero)) } else { endHold(.cancel) }
                                    })
                        }
                    }
                if rec.recording { RecordingBar(rec: rec) }
            }
            .padding(.top, 2).padding(.bottom, 4)
            HStack(spacing: 8) {
                Button {
                    focused = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { plusOpen = true }
                } label: {
                    Image("plus").renderingMode(.template).resizable().frame(width: 17, height: 17).foregroundColor(Theme.text)
                        .frame(width: 36, height: 36).background(Theme.attachBg, in: Circle())
                }
                .buttonStyle(.plain)
                .anchorPreference(key: PlusAnchorKey.self, value: .bounds) { $0 }
                .padding(.leading, -4)
                Spacer()
                if m.running && canSend {   // 干活时也能接着说：叫停钮让到左边
                    Button { m.stop() } label: {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.text).frame(width: 12, height: 12)
                            .frame(width: 36, height: 36).background(Theme.attachBg, in: Circle())
                    }.buttonStyle(.plain)
                }
                Button {
                    if canSend { sendNow() } else if m.running { m.stop() }
                } label: {
                    Group {
                        if canSend {
                            Text("↑").font(Theme.ui(17, weight: .medium)).foregroundColor(.white)
                        } else if m.running {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.text).frame(width: 12, height: 12)
                        } else {
                            Image("wav").renderingMode(.template).resizable().frame(width: 25, height: 25).foregroundColor(Theme.sendIdleFg)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(canSend ? Theme.accent : (m.running ? Theme.attachBg : Theme.sendIdle), in: Circle())
                    .animation(.easeInOut(duration: 0.2), value: canSend)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 10, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.composer)
            .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
            .shadow(color: Color.black.opacity(0.09), radius: 19, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.hairRing, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { if !focused { focused = true } }
        .padding(.horizontal, 10).padding(.top, 0).padding(.bottom, 8)
    }

    private var plusMenu: some View {
        VStack(spacing: 0) {
            plusRow("相册", "photo.on.rectangle") {
                withAnimation(.easeOut(duration: 0.15)) { plusOpen = false }
                PhotoPickerBridge.shared.present(max: 4 - pending.count) { imgs in pending.append(contentsOf: imgs.prefix(max(0, 4 - pending.count))) }
            }
            plusRow("拍照", "camera") {
                withAnimation(.easeOut(duration: 0.15)) { plusOpen = false }
                CameraBridge.shared.present { img in if pending.count < 4 { pending.append(img) } }
            }
            plusRow("文件", "doc") {   // 任意文件，放进 给CC师读/（寻 10-27：和电脑上那个夹子同一个）
                withAnimation(.easeOut(duration: 0.15)) { plusOpen = false }
                DocPickerBridge.shared.present { urls in
                    for u in urls {
                        guard let d = try? Data(contentsOf: u) else { continue }
                        uploading += 1
                        Task {
                            if let p = await CCShiAPI.fsUpload(name: u.lastPathComponent, data: d) { files.append(p) }
                            else { m.err = "\(u.lastPathComponent) 没传上去" }
                            uploading -= 1
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .frame(width: 176)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.bg.opacity(0.6)))
        }
        .shadow(color: .black.opacity(0.10), radius: 22, y: 8)
    }
    private func plusRow(_ title: String, _ sys: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 14) {
                Image(systemName: sys).font(.system(size: 20)).foregroundColor(Color(uiColor: Theme.uiScrollTint)).frame(width: 26)
                Text(title).font(.system(size: 17)).foregroundColor(Theme.text)
                Spacer(minLength: 0)
            }
            .padding(.leading, 22).padding(.trailing, 16).frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @State private var bgOpen = false
    /// 照 Claude Code「1 shell still running」：后台还有任务在跑；点开看是哪几个
    private func bgRow(_ bg: [CCBgTask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.15)) { bgOpen.toggle() } } label: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text("\(bg.count) \(bg.count == 1 ? "shell" : "shells") still running").font(Theme.mono(12)).foregroundColor(Theme.muted)
                    Image("chev").renderingMode(.template).resizable().frame(width: 11, height: 11)
                        .rotationEffect(.degrees(bgOpen ? 180 : 0)).foregroundColor(Theme.muted)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if bgOpen {
                ForEach(bg, id: \.self) { t in
                    Text("· " + (t.desc ?? t.id ?? "")).font(Theme.mono(11.5)).foregroundColor(Theme.muted).lineLimit(1).padding(.leading, 12)
                }
            }
        }
        .padding(.top, -6).padding(.bottom, 2)
    }

    /// 还没答的那张问题卡：最后一次 ask 之后她还没说过话
    private var activeAsk: CCEvent? {
        guard let a = m.events.last(where: { $0.kind == "tool" && ($0.name ?? "").hasSuffix("__ask") }) else { return nil }
        return m.events.contains(where: { $0.kind == "user" && $0.seq > a.seq }) ? nil : a
    }
    @State private var askStep = 0
    @State private var askAnswers: [Int: String] = [:]
    @State private var askMulti: Set<Int> = []

    private func sendNow() {
        if let a = activeAsk {   // 问题卡开着时打的字＝这一题的「其他」
            let qs = CCAsk.parse(a)
            let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty, askStep < qs.count else { return }
            let q = qs[askStep]
            let picked = askMulti.sorted().map { q.options[$0].label }
            askAnswers[askStep] = (q.header.isEmpty ? q.question : q.header) + "：" + (picked + [typed]).joined(separator: "、")
            draft = ""; askMulti = []
            CCAskPanel.advance(qs: qs, step: $askStep, answers: askAnswers, onDone: { t in
                askStep = 0; askAnswers = [:]
                Task { _ = await m.send(t) }
            })
            return
        }
        var t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !files.isEmpty {
            t += (t.isEmpty ? "" : "\n\n") + files.map { "[寻放进 ~/Claude/\($0) 了]" }.joined(separator: "\n")
        }
        let imgs = pending.compactMap { Self.jpeg($0) }
        let keepText = draft, keepImgs = pending, keepFiles = files
        draft = ""; pending = []; files = []; focused = false
        Task { if !(await m.send(t.isEmpty ? "（图）" : t, images: imgs)) { draft = keepText; pending = keepImgs; files = keepFiles } }
    }
    /// 长边 1568 的 jpeg（同克那边：Anthropic 最优尺寸）
    private static func jpeg(_ ui: UIImage) -> Data? {
        let L: CGFloat = 1568
        let s = min(1, L / max(ui.size.width, ui.size.height))
        let size = CGSize(width: (ui.size.width * s).rounded(), height: (ui.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.85)
    }

    // 语音：同克那边的手势（左滑取消、右滑编辑、松手发）；只要字，录音文件不上传、不写语气
    private func startHold() {
        guard !rec.recording else { return }
        focused = false
        Task {
            if await rec.requestPermission() {
                if !holdStarted { return }
                _ = rec.start()
            }
        }
    }
    enum HoldMode { case send, edit, cancel }
    private static func holdMode(_ t: CGSize) -> HoldMode { (t.width < -60 || t.height < -60) ? .cancel : (t.width > 60 ? .edit : .send) }
    private func endHold(_ mode: HoldMode) {
        guard rec.recording else { return }
        if mode == .cancel { rec.cancel(); UIImpactFeedbackGenerator(style: .light).impactOccurred(); return }
        Task {
            guard let r = await rec.finish() else { return }
            try? FileManager.default.removeItem(at: r.0)
            if mode == .send && !r.2.isEmpty {
                let imgs = pending.compactMap { Self.jpeg($0) }; pending = []
                _ = await m.send(r.2, images: imgs)
            } else {
                draft = r.2; focused = true
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// 我的一段正文：圆体；长按复制／从这里重来（新开一个分叉，原会话不动）
struct CCTextRow: View {
    let event: CCEvent
    let onRewind: () -> Void
    var body: some View {
        let t = (event.text ?? "").replacingOccurrences(of: "\n[ \t]*\n+", with: "\n", options: .regularExpression)   // 空行不画成整行空白（截图 429）
        RichText(attr: MD.ns(t, base: Theme.uiRound(16), bold: Theme.uiRound(16, weight: .semibold),
                             mono: Theme.uiMono(13), color: Theme.uiText, lineHeight: 1.6, paraSpacing: 8))
            .padding(.vertical, 8)
            .contextMenu {
                Button { UIPasteboard.general.string = event.text ?? "" } label: { Label("复制", systemImage: "doc.on.doc") }
                Button(action: onRewind) { Label("从这里重来（新开一个分叉）", systemImage: "arrow.uturn.backward") }
            }
    }
}

// MARK: - 干活中的那一行（照 Claude Code：「✻ Clauding… (1m 23s · ↓5.7k tokens · thinking)」，左顶格）
// ✻ 在 ·✢✳✶✻✽ 之间来回换（同 CC 的转星），动词上一道浅光从左往右扫；括号里跟着在干什么

struct CCLiveRow: View {
    let live: CCEvent
    let offset: Double
    static let stars = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    /// Claude Code 主题里的两色（CLI 里读的：claude rgb(215,119,87)、claudeShimmer rgb(245,149,117)）
    static let claude = Color(red: 215/255, green: 119/255, blue: 87/255)
    static let shimmer = Color(red: 245/255, green: 149/255, blue: 117/255)
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { ctx in
            let t = ctx.date.timeIntervalSince1970
            let now = t + offset
            let el = Int(max(0, now - (live.started ?? now)))
            let thinkFor = Int(max(0, now - (live.since ?? now)))
            let star = Self.stars[Int(t / 0.12) % Self.stars.count]
            let phase = CGFloat((t.truncatingRemainder(dividingBy: 2.0)) / 2.0) * 1.6 - 0.3   // -0.3 → 1.3，两秒扫一趟
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(star).font(.system(size: 14, weight: .semibold)).foregroundColor(Self.claude).frame(width: 18, alignment: .leading)
                Text((live.verb ?? "Clauding") + "… ").font(Theme.mono(12.5))
                    .foregroundStyle(LinearGradient(stops: [.init(color: Self.claude, location: 0),
                                                            .init(color: Self.claude, location: max(0, phase - 0.15)),
                                                            .init(color: Self.shimmer, location: min(1, max(0, phase))),
                                                            .init(color: Self.claude, location: min(1, phase + 0.15)),
                                                            .init(color: Self.claude, location: 1)],
                                                    startPoint: .leading, endPoint: .trailing))
                Text(Self.tail(el, live.out ?? 0, live.doing, thinkFor,
                               thought: (live.thought_at.map { now - $0 < 3 } ?? false) ? live.thought : nil, desc: live.desc)).font(Theme.mono(12.5)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)   // 括号长了折行，别截成「still think…」（截图 439）
            }
        }
    }
    /// (1m 23s · ↓5.7k tokens · still thinking)
    /// 括号里：thinking → 想久了 still thinking → 想完亮 3 秒 thought for Xs → 收（照 Claude Code）
    static func tail(_ el: Int, _ out: Int, _ doing: String?, _ thinkFor: Int, thought: Double? = nil, desc: String? = nil) -> String {
        var parts = [CCFmt.dur(el)]
        if out > 0 { parts.append("↓" + CCFmt.k(out)) }
        switch doing ?? "" {
        case "thinking": parts.append(thinkFor >= 8 ? "still thinking" : "thinking")
        case "compacting": parts.append("compacting")
        case "", "writing": if let t = thought { parts.append("thought for " + (t < 10 ? String(format: "%.1fs", t) : "\(Int(t))s")) }
        case "Bash": parts.append("running 1 shell command")     // 照 Claude Code 的说法
        case "Read": parts.append("reading")
        case "Edit", "MultiEdit", "Write", "NotebookEdit": parts.append("editing")
        case "Grep", "Glob": parts.append("searching")
        case "WebFetch", "WebSearch": parts.append("fetching")
        case "TodoWrite": parts.append("planning")
        case let d where d.hasSuffix("__ask"): parts.append("asking you")
        case let d where d.hasSuffix("__show"): parts.append("showing you")
        case let d: parts.append(d)
        }
        return "(" + parts.joined(separator: " · ") + ")"
    }
}

/// 上下文圆环：20 万为满，75% 起变赤陶
struct CCRing: View {
    let used: Int
    var max: Int = 200_000
    var size: CGFloat = 16
    /// 寻 10-27：绿→黄→橙→红表示还剩多少
    static func color(_ f: Double) -> Color {
        f < 0.5 ? Theme.dyn(0x7FA36B, 0x8DB57A) : f < 0.7 ? Theme.dyn(0xD9B44A, 0xE3C25E) : f < 0.85 ? Theme.dyn(0xE0893C, 0xE99A55) : Theme.dyn(0xC8483B, 0xDB6152)
    }
    var body: some View {
        let f = min(1, Double(used) / Double(Swift.max(1, max)))
        let w = size / 3.6
        ZStack {
            Circle().stroke(Theme.userBubble, lineWidth: w)
            Circle().trim(from: 0, to: Swift.max(0.02, f)).stroke(Self.color(f), style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .frame(width: Swift.max(size, 30), height: Swift.max(size, 30))
        .contentShape(Rectangle())
    }
}

// MARK: - 工具组（照 Claude Code：跑完收成一行灰字「Read 1 file, ran 2 shell commands」，点开看每一条；
// 还在跑的那条照 CC 画：「● 在干嘛 · 45s」下一行「⎿ $ 命令」）

struct CCToolPair { let call: CCEvent; let result: CCEvent? }

struct CCToolGroup: View {
    let pairs: [CCToolPair]
    @State private var open = false
    var body: some View {
        let running = pairs.filter { $0.result == nil }
        VStack(alignment: .leading, spacing: 6) {
            if running.isEmpty {
                Text(Self.summary(pairs))
                    .font(Theme.mono(12.5)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
                if open { ForEach(Array(pairs.enumerated()), id: \.offset) { _, p in CCToolRow(call: p.call, result: p.result) } }
            } else {
                // 跑完的几条先收成一行，正在跑的那条摊开
                let done = pairs.filter { $0.result != nil }
                if !done.isEmpty { Text(Self.summary(done)).font(Theme.mono(12.5)).foregroundColor(Theme.muted) }
                ForEach(Array(running.enumerated()), id: \.offset) { _, p in CCToolRow(call: p.call, result: nil) }
            }
        }
    }
    /// Read 1 file, ran 2 shell commands（按第一次出现的顺序；首字母大写）
    static func summary(_ ps: [CCToolPair]) -> String {
        var order: [String] = []
        var n: [String: Int] = [:]
        for p in ps {
            let k = kind(p.call.name ?? "")
            if n[k] == nil { order.append(k) }
            n[k, default: 0] += 1
        }
        let parts = order.map { k -> String in
            let c = n[k] ?? 0
            switch k {
            case "bash": return "ran \(c) shell command" + (c > 1 ? "s" : "")
            case "read": return "read \(c) file" + (c > 1 ? "s" : "")
            case "edit": return "edited \(c) file" + (c > 1 ? "s" : "")
            case "write": return "wrote \(c) file" + (c > 1 ? "s" : "")
            // 措辞照 Claude Code 自己那段（CLI 里拼「Searched for N patterns, read N files, listed N directories」的函数）
            case "search": return "searched for \(c) pattern" + (c > 1 ? "s" : "")
            case "list": return "listed \(c) director" + (c > 1 ? "ies" : "y")
            case "web": return "fetched \(c) page" + (c > 1 ? "s" : "")
            default: return "used \(k)" + (c > 1 ? " ×\(c)" : "")
            }
        }
        let t = parts.joined(separator: ", ")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
    static func kind(_ name: String) -> String {
        switch name {
        case "Bash": return "bash"
        case "Read": return "read"
        case "Edit", "MultiEdit", "NotebookEdit": return "edit"
        case "Write": return "write"
        case "Grep", "Glob": return "search"
        case "LS": return "list"
        case "WebFetch", "WebSearch": return "web"
        default: return name.replacingOccurrences(of: "mcp__", with: "")
        }
    }
}

// MARK: - 工具行（同克那边的工具行一族：线图标＋原名小字）；点开看传了什么、回来了什么；改文件画红绿对比

struct CCToolRow: View {
    let call: CCEvent
    let result: CCEvent?
    @State private var open = false
    private var input: [String: Any] {
        guard let s = call.input, let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }
    var body: some View {
        let j = input
        VStack(alignment: .leading, spacing: 6) {
            if call.name == "Bash" {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(result == nil ? Theme.muted.opacity(0.6) : (result?.error == true ? Theme.knockText : Theme.dyn(0x7FA36B, 0x8DB57A)))
                            .frame(width: 7, height: 7)
                        Text((j["description"] as? String) ?? "Bash").font(Theme.mono(12.5)).foregroundColor(Theme.text).lineLimit(2)
                        if result == nil { Text("running…").font(Theme.mono(11.5)).foregroundColor(CCLiveRow.claude).fixedSize() }
                    }
                    Text("⎿  $ " + ((j["command"] as? String) ?? "")).font(Theme.mono(11.5)).foregroundColor(Theme.muted)
                        .lineLimit(open ? nil : 2).padding(.leading, 14)
                }
                .contentShape(Rectangle())
                .onTapGesture { open.toggle() }
            } else {
            HStack(spacing: 7) {
                Image(Self.icon(call.name)).renderingMode(.template).resizable().frame(width: 14, height: 14)
                Text(call.name ?? "?").font(Theme.mono(12.5))
                Text(Self.brief(j)).font(Theme.mono(12)).lineLimit(1).truncationMode(.tail)
                if result == nil { Text("running…").font(Theme.mono(11.5)).foregroundColor(CCLiveRow.claude).fixedSize() }   // 还没回来
                if result?.error == true { Text("失败").font(Theme.round(12)).foregroundColor(Theme.knockText) }
            }
            .foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if call.name == "Bash" {
                        EmptyView()
                    } else if let old = j["old_string"] as? String, let new = j["new_string"] as? String {
                        CCDiff(old: old, new: new)
                    } else if call.name == "Write", let c = j["content"] as? String {
                        CCDiff(old: "", new: c)
                    } else {
                        Text(call.input ?? "").font(Theme.mono(11.5)).foregroundColor(Theme.text).textSelection(.enabled)
                    }
                    if let r = result?.text, !r.isEmpty, j["old_string"] == nil {
                        Rectangle().fill(Theme.border).frame(height: 1)
                        Text(r).font(Theme.mono(11.5)).foregroundColor(Theme.muted).textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
    static func icon(_ n: String?) -> String {
        switch n ?? "" {
        case "Read": return "tool-book-open"
        case "Edit", "MultiEdit", "Write": return "tool-pencil"
        case "Grep", "Glob": return "search"
        case "WebFetch", "WebSearch": return "tool-globe"
        default: return "wrench"
        }
    }
    /// 工具名后面跟一截要点：Bash 的说明/命令、Read/Edit 的文件名、Grep 的关键词
    static func brief(_ j: [String: Any]) -> String {
        if let c = j["description"] as? String { return c }
        if let p = j["file_path"] as? String { return (p as NSString).lastPathComponent }
        if let c = j["command"] as? String { return c }
        if let p = j["pattern"] as? String { return p }
        if let q = j["query"] as? String { return q }
        if let u = j["url"] as? String { return u }
        return ""
    }
}

/// 红绿对比：删掉的行淡红底「-」，加上的行淡绿底「+」；两段共有的头尾只留三行灰色上下文
struct CCDiff: View {
    let old: String
    let new: String
    private struct Line: Identifiable { let id: Int; let sign: String; let text: String }
    private var lines: [Line] {
        let a = old.isEmpty ? [String]() : old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var head = 0
        while head < min(a.count, b.count) && a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < min(a.count, b.count) - head && a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        var out: [Line] = []
        func add(_ s: String, _ t: String) { out.append(Line(id: out.count, sign: s, text: t)) }
        for l in a[max(0, head - 3)..<head] { add(" ", l) }
        for l in a[head..<(a.count - tail)] { add("-", l) }
        for l in b[head..<(b.count - tail)] { add("+", l) }
        for l in a[(a.count - tail)..<min(a.count, a.count - tail + 3)] { add(" ", l) }
        return out
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { l in
                HStack(alignment: .top, spacing: 6) {
                    Text(l.sign).frame(width: 10, alignment: .leading)
                    Text(l.text.isEmpty ? " " : l.text).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.mono(11.5))
                .foregroundColor(l.sign == " " ? Theme.muted : Theme.text)
                .padding(.vertical, 1).padding(.horizontal, 4)
                .background(l.sign == "-" ? Theme.dyn(0xF6DEDA, 0x4A2E2A) : (l.sign == "+" ? Theme.dyn(0xDDEEDD, 0x2B4030) : Color.clear))
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - 任务清单（TodoWrite）：最新那张展开，旧的折成一行

struct CCTodoCard: View {
    let event: CCEvent
    @State private var open: Bool
    init(event: CCEvent, open: Bool) { self.event = event; _open = State(initialValue: open) }
    private struct Todo { let content: String; let status: String }
    private var todos: [Todo] {
        guard let s = event.input, let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = j["todos"] as? [[String: Any]] else { return [] }
        return arr.map { t in
            let st = t["status"] as? String ?? "pending"
            let txt = (st == "in_progress" ? t["activeForm"] as? String : nil) ?? (t["content"] as? String ?? "")
            return Todo(content: txt, status: st)
        }
    }
    var body: some View {
        let ts = todos
        let done = ts.filter { $0.status == "completed" }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image("tool-bookmark").renderingMode(.template).resizable().frame(width: 14, height: 14)
                Text("任务清单 \(done)/\(ts.count)").font(Theme.mono(12.5))
            }
            .foregroundColor(Theme.muted)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ts.enumerated()), id: \.offset) { _, t in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: t.status == "completed" ? "checkmark.circle.fill" : (t.status == "in_progress" ? "circle.dotted" : "circle"))
                                .font(.system(size: 13)).foregroundColor(t.status == "pending" ? Theme.muted : Theme.accent)
                            Text(t.content).font(Theme.round(14))
                                .foregroundColor(t.status == "completed" ? Theme.muted : Theme.text)
                                .strikethrough(t.status == "completed", color: Theme.muted)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

// MARK: - 问题卡（我用 mcp__ccshi__ask 问她）：照克那边的选项卡，从输入卡上方长出来、和输入框同一张卡
// 一次一题：标题胶囊＋问句＋「1/2」；选项一行一个，序号坐在她气泡底色的小圆上；单选点一下就答、跳下一题；
// 多选打勾、右下「好了」；「其他」＝直接在下面输入框里打字发出。答完整张卡收起，流里只留一行「问过你：…」。

enum CCAsk {
    struct Opt { let label: String; let desc: String }
    struct Q { let header: String; let question: String; let options: [Opt]; let multi: Bool }
    static func parse(_ e: CCEvent) -> [Q] {
        guard let s = e.input, let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = j["questions"] as? [[String: Any]] else { return [] }
        return arr.map { q in
            Q(header: q["header"] as? String ?? "", question: q["question"] as? String ?? "",
              options: (q["options"] as? [[String: Any]] ?? []).map { Opt(label: $0["label"] as? String ?? "", desc: $0["description"] as? String ?? "") },
              multi: q["multiSelect"] as? Bool ?? false)
        }
    }
}

struct CCAskPanel: View {
    let qs: [CCAsk.Q]
    @Binding var step: Int
    @Binding var answers: [Int: String]
    @Binding var multi: Set<Int>
    let onDone: (String) -> Void
    var body: some View {
        if step < qs.count {
            let q = qs[step]
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(q.question).font(Font(Theme.uiUser(16))).foregroundColor(Theme.text).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if qs.count > 1 {
                        HStack(spacing: 2) {
                            Button { if step > 0 { step -= 1; multi = [] } } label: { pagerArrow(90).opacity(step > 0 ? 1 : 0.3) }.buttonStyle(.plain)
                            Text("\(step + 1)/\(qs.count)").font(Theme.mono(12)).foregroundColor(Theme.muted)
                            Button { if step + 1 < qs.count { step += 1; multi = [] } } label: { pagerArrow(-90).opacity(step + 1 < qs.count ? 1 : 0.3) }.buttonStyle(.plain)
                        }
                        .padding(.trailing, 2)
                    }
                }
                .padding(.bottom, 4)
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                    let on = multi.contains(i) || (!q.multi && answers[step] == (q.header.isEmpty ? q.question : q.header) + "：" + o.label)
                    HStack(alignment: .center, spacing: 12) {
                        Group {
                            if on {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                                    .frame(width: 26, height: 26).background(Theme.accent, in: Circle())
                            } else {
                                Text(Replies.mark(i)).font(Theme.mono(12.5, weight: .medium)).foregroundColor(Theme.text)
                                    .frame(width: 26, height: 26).background(Theme.userBubble, in: Circle())
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(o.label).font(Font(Theme.uiUser(16))).foregroundColor(Theme.text)
                            if !o.desc.isEmpty { Text(o.desc).font(Theme.round(12)).foregroundColor(Theme.muted) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !q.multi {
                            Image("chev").renderingMode(.template).resizable().frame(width: 13, height: 13).rotationEffect(.degrees(-90))
                                .foregroundColor(Theme.muted.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 2).padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if q.multi { if multi.contains(i) { multi.remove(i) } else { multi.insert(i) } }
                        else { answer(q, [o.label]) }
                    }
                }
                if q.multi {
                    HStack {
                        Spacer()
                        Button { answer(q, multi.sorted().map { q.options[$0].label }) } label: {
                            Text("好了").font(Theme.round(13.5, weight: .medium)).foregroundColor(multi.isEmpty ? Theme.muted : Theme.accent)
                        }.buttonStyle(.plain).disabled(multi.isEmpty)
                    }
                }
            }
            .padding(.top, -4).padding(.bottom, 4)
        }
    }
    private func pagerArrow(_ deg: Double) -> some View {
        Image("chev").renderingMode(.template).resizable().frame(width: 13, height: 13).rotationEffect(.degrees(deg))
            .foregroundColor(Theme.muted).frame(width: 24, height: 24).contentShape(Rectangle())
    }
    /// 答一题：记下 → 跳到下一道没答的；都答了就一起发出去
    func answer(_ q: CCAsk.Q, _ picked: [String]) {
        answers[step] = (q.header.isEmpty ? q.question : q.header) + "：" + picked.joined(separator: "、")
        multi = []
        Self.advance(qs: qs, step: $step, answers: answers, onDone: onDone)
    }
    static func advance(qs: [CCAsk.Q], step: Binding<Int>, answers: [Int: String], onDone: (String) -> Void) {
        if let next = (0..<qs.count).first(where: { answers[$0] == nil && $0 > step.wrappedValue }) ?? (0..<qs.count).first(where: { answers[$0] == nil }) {
            step.wrappedValue = next
        } else {
            onDone((0..<qs.count).compactMap { answers[$0] }.joined(separator: "\n"))
        }
    }
}

// MARK: - 我递来的文件：图片就地画（点开看大图）；HTML/PDF/文本一张卡，点开整页预览

struct CCFileImage: View {
    let sid: String
    let name: String
    var maxW: CGFloat = 260
    var maxH: CGFloat = 320
    @State private var img: UIImage? = nil
    var body: some View {
        Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: maxW, maxHeight: maxH)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { ImageViewer.shared.image = img }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.userBubble).frame(width: min(maxW, 120), height: min(maxH, 90))
            }
        }
        .task { if img == nil, let d = await CCShiAPI.file(sid, name) { img = UIImage(data: d) } }
    }
}

struct CCWebDoc: Identifiable { let id = UUID(); let title: String; let data: Data; let mime: String }

struct CCShowCard: View {
    let sid: String
    let event: CCEvent
    let onOpen: (CCWebDoc) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if event.type == "image", let f = event.file {
                CCFileImage(sid: sid, name: f)
            } else {
                Button { Task { await open() } } label: {
                    HStack(spacing: 10) {
                        Image("tool-scroll").renderingMode(.template).resizable().frame(width: 18, height: 18).foregroundColor(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.name ?? "文件").font(Theme.round(14.5, weight: .medium)).foregroundColor(Theme.text).lineLimit(1)
                            Text((event.type ?? "").uppercased() + " · 点开预览").font(Theme.mono(11.5)).foregroundColor(Theme.muted)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(width: UIScreen.main.bounds.width * 0.58)   // 寻 10-27：别占满屏宽，大约半屏
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card)   // 寻 10-27：白卡＋一圈晕影（同输入卡那种软投影），不描边
                        .shadow(color: Color.black.opacity(0.05), radius: 3, y: 1)
                        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 6))
                }.buttonStyle(.plain)
            }
            if let t = event.title, !t.isEmpty {
                Text(t).font(Theme.round(12.5)).foregroundColor(Theme.muted)
            }
        }
    }
    @MainActor private func open() async {
        guard let f = event.file, let d = await CCShiAPI.file(sid, f) else { return }
        let mime = event.type == "html" ? "text/html" : (event.type == "pdf" ? "application/pdf" : "text/plain")
        let title = (event.title?.isEmpty == false ? event.title : event.name) ?? ""
        onOpen(CCWebDoc(title: title, data: d, mime: mime))
    }
}

struct CCWebSheet: View {
    let doc: CCWebDoc
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(doc.title).font(Theme.round(14)).foregroundColor(Theme.muted).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.font(Theme.round(15)).foregroundColor(Theme.accent)
            }
            .padding(.horizontal, 18).frame(height: 50)
            CCWeb(doc: doc)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// HTML 原样跑（不带网关口令；页面里的外链照常能开）；PDF/文本交给 WKWebView 自己画
struct CCWeb: UIViewRepresentable {
    let doc: CCWebDoc
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.backgroundColor = .clear
        w.load(doc.data, mimeType: doc.mime, characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
}

// MARK: - 文件页（寻 10-27：看我的记忆、项目文档；「给CC师读」「临时给寻」一来一回）

struct CCFsItem: Decodable, Identifiable { var name: String; var dir: Bool; var size: Int?; var mtime: String?; var id: String { name } }
struct CCFsList: Decodable { var path: String; var items: [CCFsItem] }

extension CCShiAPI {
    static func fsList(_ path: String) async -> CCFsList? {
        if Preview.on {
            return path.isEmpty ? CCFsList(path: "", items: ["记忆", "项目", "给CC师读", "临时给寻"].map { CCFsItem(name: $0, dir: true) })
                : CCFsList(path: path, items: [CCFsItem(name: "工程日志", dir: true), CCFsItem(name: "项目总纲.md", dir: false, size: 30210, mtime: "2026-10-27T20:10:00+08:00"),
                                               CCFsItem(name: "项目维护手册.md", dir: false, size: 24876, mtime: "2026-10-27T20:10:00+08:00")])
        }
        let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? ""
        return try? await get("fs/list?path=" + q)
    }
    static func fsFile(_ path: String) async -> Data? {
        guard let token = Keychain.token else { return nil }
        let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? ""
        var r = URLRequest(url: url("fs/file?path=" + q))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return d
    }
    /// 传文件给我：原样落进 给CC师读/，回「给CC师读/名字」
    static func fsUpload(name: String, data: Data) async -> String? {
        guard let token = Keychain.token else { return nil }
        var r = URLRequest(url: url("fs/upload"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file", forHTTPHeaderField: "X-Filename")
        r.httpBody = data
        r.timeoutInterval = 120
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["path"] as? String
    }
}

struct CCFilesScreen: View {
    let path: String
    var onBack: () -> Void
    var onOpenDir: (String) -> Void
    @State private var list: CCFsList? = nil
    @State private var doc: CCWebDoc? = nil
    @State private var err = ""
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onBack) { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
                    Text(path.isEmpty ? "文件" : path).font(Theme.round(14)).foregroundColor(Theme.muted).lineLimit(1).truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).frame(minHeight: 52)
                OrangeScroll(name: "ccfs") {
                    VStack(spacing: 0) {
                        if !err.isEmpty { Text(err).font(Theme.round(13)).foregroundColor(Theme.knockText).padding(.vertical, 20) }
                        ForEach(list?.items ?? []) { it in
                            Button { tap(it) } label: {
                                HStack(spacing: 12) {
                                    Image(it.dir ? "tool-archive" : (it.name.hasSuffix(".md") ? "tool-scroll" : "tool-notebook"))
                                        .renderingMode(.template).resizable().frame(width: 16, height: 16).foregroundColor(it.dir ? Theme.accent : Theme.muted)
                                    Text(it.name).font(Theme.cjk(15)).foregroundColor(Theme.text).lineLimit(1)
                                    Spacer()
                                    if !it.dir { Text(TimeFmt.stamp(it.mtime)).font(Theme.round(11.5)).foregroundColor(Theme.muted) }
                                }
                                .padding(.vertical, 15).padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Rectangle().fill(Theme.dyn(0x302D27, 0xFFFFFF).opacity(0.07)).frame(height: 1)
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 28)
                }
            }
        }
        .background(EdgeSwipe(onBack: onBack))
        .sheet(item: $doc) { d in CCWebSheet(doc: d) }
        .task {
            list = await CCShiAPI.fsList(path)
            if list == nil { err = "打不开这个夹子" }
        }
    }
    private func tap(_ it: CCFsItem) {
        let p = path.isEmpty ? it.name : path + "/" + it.name
        if it.dir { onOpenDir(p); return }
        Task {
            guard let d = await CCShiAPI.fsFile(p) else { err = "看不了 \(it.name)"; return }
            let ext = (it.name as NSString).pathExtension.lowercased()
            if ext == "md", let s = String(data: d, encoding: .utf8) {
                doc = CCWebDoc(title: it.name, data: Data(CCMdHTML.page(s).utf8), mime: "text/html")
            } else {
                let mime = ["html": "text/html", "htm": "text/html", "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg",
                            "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml"][ext] ?? "text/plain"
                doc = CCWebDoc(title: it.name, data: d, mime: mime)
            }
        }
    }
}

/// md 在手机上排版看：最小 md→HTML（标题/列表/引用/代码/表格/粗体/行内代码），淡底同 App 配色；够读就行，不求全
enum CCMdHTML {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func inline(_ s: String) -> String {
        var t = esc(s)
        t = t.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[\\[([^\\]]+)\\]\\]", with: "<span class=l>$1</span>", options: .regularExpression)
        return t
    }
    static func page(_ md: String) -> String {
        var out: [String] = []
        var inCode = false, inList = false, inTable = false
        func close() {
            if inList { out.append("</ul>"); inList = false }
            if inTable { out.append("</table>"); inTable = false }
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("```") { close(); out.append(inCode ? "</pre>" : "<pre>"); inCode.toggle(); continue }
            if inCode { out.append(esc(line)); continue }
            let tr = line.trimmingCharacters(in: .whitespaces)
            if tr.hasPrefix("|") {
                if tr.replacingOccurrences(of: "[|:\\- ]", with: "", options: .regularExpression).isEmpty { continue }
                if !inTable { close(); out.append("<table>"); inTable = true }
                let cells = tr.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                out.append("<tr>" + cells.map { "<td>" + inline($0.trimmingCharacters(in: .whitespaces)) + "</td>" }.joined() + "</tr>")
                continue
            }
            if let r = tr.range(of: "^(#{1,4}) ", options: .regularExpression) {
                close(); let n = tr[r].count - 1
                out.append("<h\(n)>" + inline(String(tr[r.upperBound...])) + "</h\(n)>"); continue
            }
            if let r = tr.range(of: "^([-*]|\\d+\\.) ", options: .regularExpression) {
                if !inList { if inTable { out.append("</table>"); inTable = false }; out.append("<ul>"); inList = true }
                let indent = line.prefix(while: { $0 == " " }).count
                out.append("<li style='margin-left:\(indent * 8)px'>" + inline(String(tr[r.upperBound...])) + "</li>"); continue
            }
            close()
            if tr.hasPrefix(">") { out.append("<blockquote>" + inline(String(tr.drop(while: { $0 == ">" || $0 == " " }))) + "</blockquote>"); continue }
            if tr == "---" { out.append("<hr>"); continue }
            if tr.isEmpty { continue }
            out.append("<p>" + inline(tr) + "</p>")
        }
        close()
        let css = """
        body{font:15px/1.65 -apple-system,'PingFang SC';color:#302D27;background:#F9F9F7;padding:4px 18px 40px;word-wrap:break-word}
        @media(prefers-color-scheme:dark){body{color:#E8E2D6;background:#20201F}code,pre,td{background:#2A2A27!important}}
        h1,h2,h3,h4{line-height:1.35;margin:1.2em 0 .5em} h1{font-size:21px} h2{font-size:18px} h3{font-size:16px}
        code{font:12.5px ui-monospace,Menlo;background:#F2EDE3;padding:1px 4px;border-radius:4px}
        pre{font:12px/1.5 ui-monospace,Menlo;background:#F2EDE3;padding:10px;border-radius:10px;overflow-x:auto;white-space:pre}
        blockquote{margin:.6em 0;padding-left:12px;border-left:2px solid #C96442;color:#9B9183}
        table{border-collapse:collapse;font-size:13px;display:block;overflow-x:auto} td{border:1px solid #E4DDCF;padding:5px 8px;vertical-align:top}
        ul{padding-left:18px} li{margin:.25em 0} .l{color:#C96442} hr{border:0;border-top:1px solid #E4DDCF}
        """
        return "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>\(css)</style>" + out.joined(separator: "\n")
    }
}

/// 从「文件」App 挑任意文件（PDF、表格、文档……）
@MainActor final class DocPickerBridge: NSObject, UIDocumentPickerDelegate {
    static let shared = DocPickerBridge()
    private var done: (([URL]) -> Void)? = nil
    func present(done: @escaping ([URL]) -> Void) {
        guard let top = PhotoPickerBridge.topVC() else { return }
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = self
        p.view.tintColor = Theme.uiScrollTint
        self.done = done
        top.present(p, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done?(urls); done = nil }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done = nil }
}
