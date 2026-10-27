import SwiftUI

/// 手机上的 CC师（10-27 寻定乙路线）：Keep → ke.seunk.cn/ccshi/…（Caddy 拿 App 口令问网关验过才放行）→ 反向隧道 → 腾讯机 ccx 小服务。
/// 后端源码在 vault `项目/脚本/腾讯机/ccshi/server.py`。多个会话；每个会话的事件按 seq 递增，断线凭最后的 seq 接上。
/// 克的字（Lora＋思源宋）只给克；CC师 的正文用圆体，一眼分得开。

struct CCSession: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var updated: String?
    var status: String?
    var last_text: String?
    var archived: Bool?
    var running: Bool { status == "running" }
}

struct CCEvent: Decodable {
    var seq: Int
    var ts: String?
    var kind: String
    var text: String?
    var name: String?
    var input: String?
    var id: String?          // tool / tool_result 的配对号
    var error: Bool?
    var secs: Int?
    var state: String?
    enum CodingKeys: String, CodingKey { case seq, ts, kind, text, name, input, id, error, secs, state }
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
    private static func req(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let token = Keychain.token else { throw GatewayAPI.Failure.unauthorized }
        // 查询串不能拼进 path（appendingPathComponent 会把 ? 转成 %3F，构建 216 撞过）
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var comps = URLComponents(url: Gateway.home.appendingPathComponent("ccshi/api/" + parts[0]), resolvingAgainstBaseURL: false)!
        if parts.count > 1 { comps.percentEncodedQuery = parts[1] }
        var r = URLRequest(url: comps.url!)
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

    static func sessions() async throws -> [CCSession] { (try await get("sessions") as List).sessions }
    static func usage() async -> CCUsage? { try? await get("usage") }
    static func create(_ title: String) async throws -> CCSession { try await get("sessions", method: "POST", body: ["title": title]) }
    static func rename(_ id: String, _ title: String) async { _ = try? await get("sessions/\(id)/rename", method: "POST", body: ["title": title]) as CCSession }
    static func archive(_ id: String, _ on: Bool) async { _ = try? await get("sessions/\(id)/archive", method: "POST", body: ["archived": on]) as CCSession }
    static func send(_ id: String, _ text: String) async throws { _ = try await get("sessions/\(id)/send", method: "POST", body: ["text": text]) as Queued }
    static func stop(_ id: String) async { _ = try? await get("sessions/\(id)/stop", method: "POST", body: [:]) as [String: Bool] }
    static func events(_ id: String, after: Int) async throws -> Events { try await get("sessions/\(id)/events?after=\(after)") }

    /// SSE：吐 after 之后的事件，连着就一直等新的；断了由调用方凭最后 seq 重连
    static func stream(_ id: String, after: Int) -> AsyncThrowingStream<CCEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    guard let token = Keychain.token else { throw GatewayAPI.Failure.unauthorized }
                    var comps = URLComponents(url: Gateway.home.appendingPathComponent("ccshi/api/sessions/\(id)/stream"), resolvingAgainstBaseURL: false)!
                    comps.queryItems = [URLQueryItem(name: "after", value: String(after))]
                    var r = URLRequest(url: comps.url!)
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
                    Button { Task { await newSession() } } label: {
                        Text("+").font(Theme.ui(27, weight: .light)).foregroundColor(Theme.text).frame(width: 34, height: 34)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).frame(minHeight: 52)
                if !m.usage.isEmpty {
                    Text(m.usage).font(Theme.round(12)).foregroundColor(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 6)
                }
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
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 28)
                }
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
                Text(s.last_text?.isEmpty == false ? s.last_text! : "（还没说话）")
                    .font(Theme.round(13)).foregroundColor(Theme.muted).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - 会话页

@MainActor final class CCShiSessionModel: ObservableObject {
    let id: String
    @Published var meta: CCSession? = nil
    @Published var events: [CCEvent] = []
    @Published var err = ""
    private var last = 0
    private var streamTask: Task<Void, Never>? = nil
    init(id: String) { self.id = id }

    var running: Bool { meta?.running == true }

    func start() {
        if Preview.on { loadPreview(); return }
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    if self.meta == nil || self.last == 0 {
                        let e = try await CCShiAPI.events(self.id, after: 0)
                        self.meta = e.meta; self.absorb(e.events)
                    }
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
        for e in evs where e.seq > last {
            events.append(e); last = e.seq
            if e.kind == "status" { meta?.status = e.state }
        }
    }

    func send(_ text: String) async -> Bool {
        do { try await CCShiAPI.send(id, text); err = ""; return true }
        catch { err = "没送出去，字留在输入框里"; return false }
    }
    func stop() { Task { await CCShiAPI.stop(id) } }

    private func loadPreview() {
        guard let d = Preview.json("preview_ccshi"), let p = try? JSONDecoder().decode(CCShiPreview.self, from: d) else { return }
        meta = p.sessions.first; events = p.events
        if Preview.screen == "ccshirun" { meta?.status = "running" }
    }
}

/// 一轮里连着的东西排成「块」：她的话、我的思考、工具（调用＋结果配对）、正文、一轮收尾的时间
private enum CCBlock: Identifiable {
    case user(CCEvent)
    case thinking(CCEvent)
    case tool(CCEvent, CCEvent?)
    case text(CCEvent)
    case end(CCEvent)
    case error(CCEvent)
    var id: Int {
        switch self {
        case .user(let e), .thinking(let e), .text(let e), .end(let e), .error(let e): return e.seq
        case .tool(let e, _): return e.seq
        }
    }
    static func build(_ evs: [CCEvent]) -> [CCBlock] {
        var out: [CCBlock] = []
        var results: [String: CCEvent] = [:]
        for e in evs where e.kind == "tool_result" { if let i = e.id { results[i] = e } }
        for e in evs {
            switch e.kind {
            case "user": out.append(.user(e))
            case "thinking": out.append(.thinking(e))
            case "tool": out.append(.tool(e, e.id.flatMap { results[$0] }))
            case "text": out.append(.text(e))
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
    @StateObject private var m: CCShiSessionModel
    @State private var draft = ""
    @State private var focused = false
    @Environment(\.scenePhase) private var phase

    init(id: String, onBack: @escaping () -> Void) {
        self.onBack = onBack
        _m = StateObject(wrappedValue: CCShiSessionModel(id: id))
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: onBack) { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
                    Text(m.meta?.title ?? "CC师").font(Theme.round(14)).foregroundColor(Theme.muted).lineLimit(1)
                    Spacer()
                    if m.running { Text("在干活").font(Theme.round(12)).foregroundColor(Theme.accent) }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).frame(minHeight: 52)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(CCBlock.build(m.events)) { b in row(b) }
                            Color.clear.frame(height: 8).id("bottom")
                        }
                        .padding(.horizontal, 18).padding(.top, 6)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: m.events.count) { _ in withAnimation(nil) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                if !m.err.isEmpty {
                    Text(m.err).font(Theme.round(12)).foregroundColor(Theme.knockText).padding(.bottom, 4)
                }
                composer
            }
        }
        .background(EdgeSwipe(onBack: onBack))
        .onAppear { m.start() }
        .onDisappear { m.stopStream() }
        .onChange(of: phase) { p in if p == .active { m.start() } }
    }

    @ViewBuilder private func row(_ b: CCBlock) -> some View {
        switch b {
        case .user(let e):
            UserRowView(text: e.text ?? "", stamp: TimeFmt.stamp(e.ts), images: []).padding(.vertical, 12)
        case .thinking(let e):
            ThinkView(text: e.text ?? "", label: "Thought").padding(.vertical, 3)
        case .tool(let call, let res):
            CCToolRow(call: call, result: res).padding(.vertical, 3)
        case .text(let e):
            RichText(attr: MD.ns(e.text ?? "", base: Theme.uiRound(16), bold: Theme.uiRound(16, weight: .semibold),
                                 mono: Theme.uiMono(13), color: Theme.uiText, lineHeight: 1.6, paraSpacing: 8))
                .textSelection(.enabled).padding(.vertical, 8)
        case .end(let e):
            Text(TimeFmt.stamp(e.ts) + (e.secs.map { "  ·  \(Self.dur($0))" } ?? ""))
                .font(Theme.round(12)).foregroundColor(Theme.muted).padding(.top, 2).padding(.bottom, 10)
        case .error(let e):
            Text(e.text ?? "出错了").font(Theme.round(13)).foregroundColor(Theme.knockText).padding(.vertical, 6)
        }
    }

    private static func dur(_ s: Int) -> String { s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒" }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Composer(text: $draft, focused: $focused, placeholder: m.running ? "接着说（排在这轮后面）…" : "跟 CC师 说…")
            HStack {
                Spacer()
                if m.running {
                    Button { m.stop() } label: {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.text).frame(width: 12, height: 12)
                            .frame(width: 36, height: 36).background(Theme.attachBg, in: Circle())
                    }.buttonStyle(.plain)
                }
                Button {
                    guard canSend else { return }
                    let t = draft; draft = ""
                    Task { if !(await m.send(t)) { draft = t } }
                } label: {
                    Text("↑").font(Theme.ui(17, weight: .medium)).foregroundColor(.white)
                        .frame(width: 36, height: 36).background(canSend ? Theme.accent : Theme.sendIdle, in: Circle())
                }.buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.composer))
        .padding(.horizontal, 10).padding(.bottom, 8)
    }
}

/// 工具一行（同克那边的工具行一族：线图标＋原名小字）；点开看我传了什么、回来了什么
struct CCToolRow: View {
    let call: CCEvent
    let result: CCEvent?
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image("wrench").renderingMode(.template).resizable().frame(width: 14, height: 14)
                Text((call.name ?? "?") + (result == nil ? "…" : "")).font(Theme.mono(12.5))
                Text(Self.brief(call)).font(Theme.mono(12)).lineLimit(1).truncationMode(.tail)
                if result?.error == true { Text("失败").font(Theme.round(12)).foregroundColor(Theme.knockText) }
            }
            .foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(call.input ?? "").font(Theme.mono(11.5)).foregroundColor(Theme.text).textSelection(.enabled)
                    if let r = result?.text, !r.isEmpty {
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
    /// 工具名后面跟一截要点：Bash 的命令、Read/Edit 的文件名、Grep 的关键词
    static func brief(_ e: CCEvent) -> String {
        guard let s = e.input, let d = s.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        if let c = j["description"] as? String { return c }
        if let p = j["file_path"] as? String { return (p as NSString).lastPathComponent }
        if let c = j["command"] as? String { return c }
        if let p = j["pattern"] as? String { return p }
        return ""
    }
}
