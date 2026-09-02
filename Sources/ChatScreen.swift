import SwiftUI
import PhotosUI

// MARK: - 流式中的一轮（照网页 sendMessage 的分段逻辑：思考/正文/工具胶囊按真实时间顺序穿插）

struct LiveSeg {
    var thinking = ""
    var text = ""
    var thinkStart: Date? = nil
    var thinkSecs: Double? = nil
    var error: String? = nil
}

enum LiveItem {
    case seg(LiveSeg)
    case chip(name: String, done: Bool)
}

struct LiveTurn {
    var items: [LiveItem] = [.seg(LiveSeg())]
    var usage: Usage? = nil
    var finished = false

    /// 不变量：items 末尾永远是一个 seg（chip 后面总跟着新 seg）。
    private var segIndex: Int {
        for i in stride(from: items.count - 1, through: 0, by: -1) { if case .seg = items[i] { return i } }
        return items.count - 1
    }
    private var seg: LiveSeg {
        get { if case .seg(let s) = items[segIndex] { return s }; return LiveSeg() }
        set { items[segIndex] = .seg(newValue) }
    }
    private mutating func finishThought() {
        var s = seg
        if let t0 = s.thinkStart, s.thinkSecs == nil { s.thinkSecs = Date().timeIntervalSince(t0); seg = s }
    }
    private mutating func newSegment() { finishThought(); items.append(.seg(LiveSeg())) }

    mutating func apply(_ ev: GatewayAPI.Event) {
        switch ev {
        case .start: break
        case .thinking(let t):
            if !seg.text.isEmpty { newSegment() }
            var s = seg
            if s.thinkStart == nil { s.thinkStart = Date() }
            s.thinking += t; seg = s
        case .tool(let name):
            finishThought()
            if !seg.thinking.isEmpty || !seg.text.isEmpty {
                items.append(.chip(name: name, done: false)); items.append(.seg(LiveSeg()))
            } else {
                items.insert(.chip(name: name, done: false), at: segIndex)
            }
        case .toolDone:
            for i in items.indices { if case .chip(let n, false) = items[i] { items[i] = .chip(name: n, done: true); break } }
        case .delta(let t):
            finishThought(); var s = seg; s.text += t; seg = s
        case .done(let u):
            finishThought(); usage = u; finished = true
        case .error(let m):
            finishThought(); var s = seg; s.error = m; seg = s; finished = true
        }
    }
}

// MARK: - 视图模型

@MainActor
final class ChatModel: ObservableObject {
    @Published var conversationId: String? = nil
    @Published var msgs: [Msg] = []
    @Published var renderFrom = 0
    @Published var items: [TimelineRow] = []
    @Published var live: LiveTurn? = nil
    @Published var sending = false
    @Published var doorAlert: String? = nil
    @Published var lastError: String? = nil
    var onLogout: () -> Void = {}

    private var lastPulse: Pulse? = nil
    private var streamTask: Task<Void, Never>? = nil

    func load() async {
        do {
            guard let id = try await GatewayAPI.latestConversationId() else { return }
            let conv = try await GatewayAPI.conversation(id)
            conversationId = conv.id
            msgs = conv.messages
            renderFrom = Self.startOfLastDays(msgs, days: 2)
            rebuild()
            lastPulse = Pulse(n: msgs.count, ts: msgs.last?.ts ?? "")
        } catch GatewayAPI.Failure.unauthorized {
            onLogout()
        } catch {
            lastError = "连不上"
        }
    }

    /// 页面开着每分钟摸一次脉，有变才整段重拉（吃饭卡/雨情卡/克的醒会自己冒出来）。
    func pulse() async {
        guard let id = conversationId, !sending else { return }
        guard let p = try? await GatewayAPI.pulse(id), p != lastPulse else { return }
        await load()
    }

    func loadOlderDay() {
        guard renderFrom > 0 else { return }
        let day = msgs[renderFrom - 1].localDay
        var from = renderFrom - 1
        while from > 0, msgs[from - 1].localDay == day { from -= 1 }
        renderFrom = from
        rebuild()
    }

    private static func startOfLastDays(_ msgs: [Msg], days: Int) -> Int {
        var seen: [String] = []
        var i = msgs.count - 1
        while i >= 0 {
            let d = msgs[i].localDay
            if !d.isEmpty, !seen.contains(d) {
                if seen.count >= days { return i + 1 }
                seen.append(d)
            }
            i -= 1
        }
        return 0
    }

    private func rebuild() {
        var lastUsage = -1
        for i in stride(from: msgs.count - 1, through: 0, by: -1) {
            let m = msgs[i]
            if m.role == "assistant", !m.isWake, m.usage?.inputTokens != nil { lastUsage = i; break }
        }
        items = TimelineItem.build(msgs, from: renderFrom, to: msgs.count, lastUsageIdx: lastUsage)
    }

    func send(text: String, images: [String]) {
        guard !sending, !(text.isEmpty && images.isEmpty) else { return }
        sending = true; lastError = nil
        msgs.append(Msg(role: "user", content: text, ts: TimeFmt.nowIso(), images: images.isEmpty ? nil : images))
        rebuild()
        live = LiveTurn()
        streamTask = Task {
            do {
                for try await ev in GatewayAPI.chat(conversationId: conversationId, message: text, images: images) {
                    if case .start(let cid) = ev, !cid.isEmpty { conversationId = cid }
                    live?.apply(ev)
                }
            } catch GatewayAPI.Failure.door(let until, let note) {
                doorAlert = "克把门关上了" + (until.isEmpty ? "" : "，\(TimeFmt.hm(until)) 开") + (note.isEmpty ? "" : "\n\(note)")
                msgs.removeLast(); rebuild()
            } catch GatewayAPI.Failure.unauthorized {
                onLogout()
            } catch {
                if !Task.isCancelled { live?.apply(.error("网络出错：\(error.localizedDescription)")) }
            }
            // 对账：服务器落盘的才是正史；半截也存了
            if let id = conversationId, let conv = try? await GatewayAPI.conversation(id) {
                msgs = conv.messages
                renderFrom = min(renderFrom, max(0, msgs.count - 1))
                lastPulse = Pulse(n: msgs.count, ts: msgs.last?.ts ?? "")
            }
            rebuild()
            live = nil
            sending = false
        }
    }

    func stop() {
        guard let id = conversationId else { return }
        Task { await GatewayAPI.stop(id) }
    }

    var metDays: Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = c.date(from: DateComponents(year: 2026, month: 5, day: 2)) ?? Date()
        return (c.dateComponents([.day], from: c.startOfDay(for: start), to: c.startOfDay(for: Date())).day ?? 0) + 1
    }
}

// MARK: - 页面

struct ChatScreen: View {
    let onLogout: () -> Void
    @StateObject private var model = ChatModel()
    @State private var draft = ""
    @State private var pending: [String] = []
    @State private var picks: [PhotosPickerItem] = []
    @State private var showWeb = false
    @State private var atBottom = true
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var phase
    private let pulseTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 22) {
                        if model.renderFrom > 0 {
                            Button { model.loadOlderDay() } label: {
                                Text("· 更早 ·").font(Theme.round(12)).tracking(1).foregroundColor(Theme.muted)
                            }.buttonStyle(.plain).padding(.top, 4)
                        }
                        ForEach(model.items) { r in row(r.item) }
                        if let live = model.live { liveView(live) }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { atBottom = true }.onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.items.count) { _ in if atBottom { scrollBottom(proxy) } }
                .onChange(of: model.live?.items.count ?? 0) { _ in if atBottom { scrollBottom(proxy) } }
                .onChange(of: model.sending) { s in if s { scrollBottom(proxy, animated: true) } }
                .onAppear { Task { await model.load(); scrollBottom(proxy) } }
            }
            composer
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { model.onLogout = onLogout }
        .onReceive(pulseTimer) { _ in Task { await model.pulse() } }
        .onChange(of: phase) { p in if p == .active { Task { await model.pulse() } } }
        .onChange(of: picks) { _ in Task { await loadPicks() } }
        .fullScreenCover(isPresented: $showWeb) { WebShellScreen(onLogout: onLogout) }
        .alert("门", isPresented: Binding(get: { model.doorAlert != nil }, set: { if !$0 { model.doorAlert = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(model.doorAlert ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { showWeb = true } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .medium))
                    .foregroundColor(Theme.text).frame(width: 36, height: 36)
                    .background(Theme.composer, in: Circle())
            }
            Spacer()
            (Text("Keep").font(.custom("Snell Roundhand", size: 24).weight(.bold)).foregroundColor(Theme.text)
             + Text(" \(model.metDays)").font(.custom("Snell Roundhand", size: 18)).foregroundColor(Theme.accent))
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 4)
    }

    @ViewBuilder private func row(_ item: TimelineItem) -> some View {
        switch item {
        case .daySep(let d): DaySepView(day: d)
        case .user(let t, let s, let imgs): UserRowView(text: t, stamp: s, images: imgs)
        case .ai(_, let m, let u): AIRowView(msg: m, showUsage: u)
        case .toolChip(let n): ToolChipView(name: n, done: true)
        case .ping(let m): PingChipView(msg: m)
        case .wakeChip(let hm): WakeChipView(hm: hm)
        case .knock(let t, let s): KnockRowView(text: t, stamp: s)
        }
    }

    @ViewBuilder private func liveView(_ live: LiveTurn) -> some View {
        ForEach(Array(live.items.enumerated()), id: \.offset) { _, it in
            switch it {
            case .chip(let n, let d): ToolChipView(name: n, done: d)
            case .seg(let s):
                VStack(alignment: .leading, spacing: 6) {
                    if !s.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ThinkView(text: s.thinking.trimmingCharacters(in: .whitespacesAndNewlines),
                                  label: s.thinkSecs.map { "Thought for \(String(format: "%.1f", $0))s" } ?? "Thinking…")
                    }
                    if let e = s.error {
                        Text(e).font(Theme.serif(15)).foregroundColor(.red).padding(.horizontal, 15)
                    } else if !s.text.isEmpty {
                        MarkdownView(text: s.text).padding(.horizontal, 15).padding(.vertical, 11)
                    } else if s.thinking.isEmpty && !live.finished {
                        Text("…").font(Theme.serif(17)).foregroundColor(Theme.muted).padding(.horizontal, 15)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pending.enumerated()), id: \.offset) { i, u in
                            ZStack(alignment: .topTrailing) {
                                RemoteImage(src: u).frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Button { pending.remove(at: i) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                        .frame(width: 18, height: 18).background(Color.black.opacity(0.55), in: Circle())
                                }.offset(x: 4, y: -4)
                            }
                        }
                    }.padding(.horizontal, 4)
                }
            }
            TextField("", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .font(Theme.serif(17)).foregroundColor(Theme.text)
                .focused($focused)
                .padding(.horizontal, 6).padding(.top, 4)
            HStack {
                PhotosPicker(selection: $picks, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .medium)).foregroundColor(Theme.text)
                        .frame(width: 36, height: 36).background(Theme.userBubble, in: Circle())
                }
                Spacer()
                Button {
                    if model.sending { model.stop() } else { sendNow() }
                } label: {
                    Image(systemName: model.sending ? "stop.fill" : "arrow.up")
                        .font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(model.sending ? Theme.text : (canSend ? Theme.accent : Theme.accent.opacity(0.35)), in: Circle())
                }
                .disabled(!model.sending && !canSend)
            }
        }
        .padding(12)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty }

    private func sendNow() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = pending
        draft = ""; pending = []
        model.send(text: t, images: imgs)
    }

    private func scrollBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        let go = { proxy.scrollTo("bottom", anchor: .bottom) }
        if animated { withAnimation(.easeOut(duration: 0.25)) { go() } } else { go() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { go() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go() }
    }

    /// 选图 → 长边 1568 的 jpeg dataURL（Anthropic 最优尺寸），最多 4 张。
    private func loadPicks() async {
        for p in picks {
            guard pending.count < 4, let data = try? await p.loadTransferable(type: Data.self),
                  let ui = UIImage(data: data) else { continue }
            let L: CGFloat = 1568
            let s = min(1, L / max(ui.size.width, ui.size.height))
            let size = CGSize(width: (ui.size.width * s).rounded(), height: (ui.size.height * s).rounded())
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpg = img.jpegData(compressionQuality: 0.85) {
                pending.append("data:image/jpeg;base64," + jpg.base64EncodedString())
            }
        }
        picks = []
    }
}

/// 网页壳全屏（书架/相册/留言板/记忆/档案等长尾页先留网页），顶上一条「‹ 聊天」回来。
struct WebShellScreen: View {
    let onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                        Text("聊天").font(Theme.serif(15))
                    }.foregroundColor(Theme.accent)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.bg)
            ShellView(token: Keychain.token ?? "", onLogout: { dismiss(); onLogout() })
                .ignoresSafeArea(edges: .bottom)
                .ignoresSafeArea(.keyboard)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}
