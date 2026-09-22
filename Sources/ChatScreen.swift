import SwiftUI
import PhotosUI

// MARK: - 流式中的一轮（照网页 sendMessage 的分段逻辑：思考/正文/工具胶囊按真实时间顺序穿插）

struct LiveSeg {
    var thinking = ""
    var text = ""
    var shown = 0                 // 打字机已放出的字数（照网页 smoothTick：块到了不砸上屏，逐帧匀速放）
    var thinkStart: Date? = nil
    var thinkSecs: Double? = nil
    var error: String? = nil
    var shownText: String { shown >= text.count ? text : String(text.prefix(shown)) }
}

enum LiveItem {
    case seg(LiveSeg)
    case chip(name: String, done: Bool)
}

struct LiveTurn {
    var items: [LiveItem] = [.seg(LiveSeg())]
    var usage: Usage? = nil
    var finished = false
    var events = 0

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
    /// 定格：封段/工具/结束/出错时把已放出的字数拨到底，别让打字机循环盖掉后画的内容
    private mutating func settle() { var s = seg; s.shown = s.text.count; seg = s }
    private mutating func newSegment() { finishThought(); settle(); items.append(.seg(LiveSeg())) }
    /// 打字机一帧（30 帧/秒）：积压越多每帧放越多（约 0.4s 追平）。放了字返回 true。
    mutating func advance() -> Bool {
        var s = seg
        let n = s.text.count
        guard s.shown < n else { return false }
        s.shown = min(n, s.shown + max(1, Int((Double(n - s.shown) / 12).rounded())))
        seg = s; events += 1
        return true
    }

    mutating func apply(_ ev: GatewayAPI.Event) {
        events += 1
        switch ev {
        case .start, .voice: break   // voice 由 ChatModel 直接写进她那条气泡
        case .thinking(let t):
            if !seg.text.isEmpty { newSegment() }
            var s = seg
            if s.thinkStart == nil { s.thinkStart = Date() }
            s.thinking += t; seg = s
        case .tool(let name):
            finishThought()
            if !seg.thinking.isEmpty || !seg.text.isEmpty {
                settle()
                items.append(.chip(name: name, done: false)); items.append(.seg(LiveSeg()))
            } else {
                items.insert(.chip(name: name, done: false), at: segIndex)
            }
        case .toolDone:
            for i in items.indices { if case .chip(let n, false) = items[i] { items[i] = .chip(name: n, done: true); break } }
        case .delta(let t):
            finishThought(); var s = seg; s.text += t; seg = s
        case .done(let u):
            finishThought(); settle(); usage = u; finished = true
        case .error(let m):
            finishThought(); settle(); var s = seg; s.error = m; seg = s; finished = true
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
    @Published var door: Door? = nil          // 门关着＝整页只剩门页（照网页 updateDoor）
    @Published var lastError: String? = nil
    private var knockBusy = false
    @Published var loadTick = 0          // 每次整段重拉 +1，页面据此滚到底
    var onLogout: () -> Void = {}

    private var lastPulse: Pulse? = nil
    private var streamTask: Task<Void, Never>? = nil
    private var lastEventAt = Date()
    private var loading = false

    func load() async {
        if loading { return }          // 开屏时 onAppear 与 scenePhase 各拉一次 → 两次重排两次滚（寻验：界面弹几下）
        loading = true; defer { loading = false }
        if Preview.on, let d = Preview.json("preview"), let conv = try? JSONDecoder().decode(ConversationPayload.self, from: d) {
            conversationId = conv.id; msgs = conv.messages; renderFrom = Self.startOfLastDays(msgs, days: 2); rebuild(); loadTick += 1
            if Preview.screen == "door" {
                let until = TimeFmt.nowIso(); _ = until
                door = Door(until: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600 * 2)), note: "去睡一会儿。\n门口的灯给你留着。",
                            knock: Door.Words(text: "我到家了。", ts: nil), reply: Door.Words(text: "好。灯在。", ts: nil))
            }
            return
        }
        // 冷启动先亮上次落盘的正史（09-03 寻验：闲置两小时后开，通道卡四十秒整页白着），网上的到了再换
        if msgs.isEmpty, let cached = GatewayAPI.cachedConversation(), !cached.messages.isEmpty { apply(cached) }
        for attempt in 0..<2 {
            do {
                guard let id = try await GatewayAPI.latestConversationId() else { return }
                let conv = try await GatewayAPI.conversation(id)
                let p = Pulse(n: conv.messages.count, ts: conv.messages.last?.ts ?? "")
                if conv.id != conversationId || p != lastPulse { apply(conv) }   // 和缓存一样就不重排不重滚
                lastPulse = p; lastError = nil
                await refreshDoor()
                return
            } catch GatewayAPI.Failure.unauthorized {
                onLogout(); return
            } catch {
                if attempt == 0 { try? await Task.sleep(nanoseconds: 1_500_000_000); continue }   // 头一回失败歇一秒半再来一次
                lastError = "连不上"
            }
        }
    }

    private var staged = false   // 冷启动分两段排过了没
    private func apply(_ conv: ConversationPayload) {
        conversationId = conv.id
        msgs = conv.messages
        let full = Self.startOfLastDays(msgs, days: 2)
        lastPulse = Pulse(n: msgs.count, ts: msgs.last?.ts ?? "")
        // 09-21 寻「开屏大半白纸」：两天有七百多条（09-20/21 各三四百），一次排完第一帧要等好几秒。
        // 冷启动先只排最近 40 条把屏画出来，0.6 秒后再把两天补齐（内容往上长、开屏落定窗会钉回底）。「主页画两天」不变。
        if !staged, msgs.count - full > 40 {
            staged = true
            renderFrom = msgs.count - 40
            rebuild(); loadTick += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                let f = Self.startOfLastDays(self.msgs, days: 2)
                if self.renderFrom > f { self.renderFrom = f; self.rebuild(); self.loadTick += 1 }
            }
            return
        }
        staged = true
        renderFrom = full
        rebuild()
        loadTick += 1
    }

    /// 页面开着每 15 秒摸一次脉，有变才整段重拉（吃饭卡/雨情卡/克的醒/网页那头发的话会自己冒出来）。
    func pulse() async {
        guard let id = conversationId else { await load(); return }
        if sending {
            // 看门狗：流开着却 120 秒没任何事件＝连接死了；收掉，交给重拉
            if Date().timeIntervalSince(lastEventAt) > 120 { streamTask?.cancel() }
            return
        }
        await refreshDoor()
        guard let p = try? await GatewayAPI.pulse(id), p != lastPulse else { return }
        await load()
    }

    /// 门的状态随脉搏捎回；门开了（到点或他提前开）就把关门期间落下的接回来
    func refreshDoor() async {
        guard !Preview.on else { return }
        let wasClosed = door?.closed == true
        let d = try? await GatewayAPI.door()
        door = (d?.closed == true) ? d : nil
        if wasClosed && door == nil { await load() }
    }

    /// 敲一句穿门：他的回应静静写进正史，门开再看；这里只把流喝完别断连接（照网页 sendKnock）
    func knock(_ text: String) async {
        guard door != nil, !knockBusy else { return }
        knockBusy = true
        let stream = GatewayAPI.chat(conversationId: conversationId, message: text, images: [], knock: true)
        Task { do { for try await _ in stream {} } catch {} }
        door?.knock = Door.Words(text: text, ts: nil)
        try? await Task.sleep(nanoseconds: 520_000_000)
        await refreshDoor()
        knockBusy = false
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

    /// 吃吃回显（寻：按时间顺序，别压到新消息下面）：本地小纸条按时间插进正史；
    /// 服务器在她下一条消息时物化出正牌纸条（同一行文案），到了就撤本地那张。
    private var localPings: [Msg] = []
    func addLocalPing(_ line: String) {
        var m = Msg(role: "user", content: line, ts: TimeFmt.nowIso()); m.meal = true; m.localEcho = true
        localPings.append(m); rebuild()
    }
    private func mergeLocalPings() {
        msgs.removeAll { $0.localEcho }
        localPings.removeAll { lp in msgs.contains { $0.isPing && $0.content == lp.content } }
        for lp in localPings {
            let i = msgs.firstIndex { ($0.date ?? .distantPast) > (lp.date ?? .distantFuture) } ?? msgs.count
            msgs.insert(lp, at: i)
        }
    }
    private func rebuild() {
        mergeLocalPings()
        var lastUsage = -1
        for i in stride(from: msgs.count - 1, through: 0, by: -1) {
            let m = msgs[i]
            if m.role == "assistant", !m.isWake, m.usage?.inputTokens != nil { lastUsage = i; break }
        }
        items = TimelineItem.build(msgs, from: renderFrom, to: msgs.count, lastUsageIdx: lastUsage)
    }

    /// 语音条（09-14 夜二版）：字已经在手机上出好（腾讯实时识别）、她定稿了；这里传音频、再当普通消息发（带 voice：定稿＋识别原文＋annotate），
    /// 网关让 Gemini 照定稿标记号写语气。先画一个转圈的小气泡＋字，传好就换成真的。失败就把小气泡下面改成一句灰字。
    @Published var transcribing = false
    /// images（09-21 寻）：输入框里已选的图随语音条一起发——之前带图就把音频丢了当普通消息发
    func sendVoice(file: URL, dur: Double, text: String, orig: String, images: [String] = []) {
        guard !sending, !transcribing, !text.isEmpty else { return }
        transcribing = true
        var echo = Msg(role: "user", content: text, ts: TimeFmt.nowIso(), images: images.isEmpty ? nil : images); echo.voice = Voice(url: "", dur: dur, text: text, pending: true)
        msgs.append(echo); rebuild()
        PushRegistrar.diag(String(format: "voice: send %.1fs chars=%d edited=%d imgs=%d", dur, text.count, text != orig ? 1 : 0, images.count))
        Task {
            defer { transcribing = false }
            do {
                var v = try await GatewayAPI.uploadVoice(file: file, dur: dur, transcribe: false)
                try? FileManager.default.removeItem(at: file)
                v.text = text; v.orig = orig; v.annotate = true
                msgs.removeAll { $0.voice?.pending == true }
                send(text: text, images: images, voice: v)
            } catch {
                PushRegistrar.diag("voice: upload failed \(error.localizedDescription)")
                voiceFailed("音频没传上去，再说一次？")
            }
        }
    }
    private func voiceFailed(_ why: String) {
        if let i = msgs.lastIndex(where: { $0.voice?.pending == true }) { msgs[i].voice?.pending = nil; msgs[i].voice?.failed = why }
        rebuild()
    }

    func send(text: String, images: [String], voice: Voice? = nil) {
        guard !sending, !(text.isEmpty && images.isEmpty) else { return }
        sending = true; lastError = nil; lastEventAt = Date()
        var um = Msg(role: "user", content: text, ts: TimeFmt.nowIso(), images: images.isEmpty ? nil : images); um.voice = voice
        msgs.append(um)
        rebuild()
        live = LiveTurn()
        PushRegistrar.diag("chat: send")
        streamTask = Task {
            do {
                for try await ev in GatewayAPI.chat(conversationId: conversationId, message: text, images: images, voice: voice) {
                    lastEventAt = Date()
                    if case .start(let cid) = ev, !cid.isEmpty { conversationId = cid; PushRegistrar.diag("chat: start") }
                    // 语气到了（09-21）：立刻写进刚发的那条语音气泡，不等克说完重拉正史
                    if case .voice(let tone, let vt) = ev, let i = msgs.lastIndex(where: { $0.role == "user" && $0.voice != nil }) {
                        if !tone.isEmpty { msgs[i].voice?.tone = tone }
                        if !vt.isEmpty { msgs[i].voice?.text = vt }
                        rebuild()
                    }
                    live?.apply(ev)
                    if case .delta = ev { startSmoother() }
                }
                PushRegistrar.diag("chat: stream closed events=\(live?.events ?? 0) finished=\(live?.finished ?? false) textLen=\(live?.items.compactMap { if case .seg(let s) = $0 { return s.text.count }; return nil }.reduce(0, +) ?? 0)")
            } catch GatewayAPI.Failure.door(let until, let note) {
                // 克把门关上了：撤下刚画的那条，字还给输入框（网页同款），门页自己升起来
                door = Door(until: until, note: note, knock: nil, reply: nil)
                msgs.removeLast(); rebuild()
                await refreshDoor()
            } catch GatewayAPI.Failure.unauthorized {
                onLogout()
            } catch {
                PushRegistrar.diag("chat: error \(error.localizedDescription)")
                if !Task.isCancelled { live?.apply(.error("网络出错：\(error.localizedDescription)")) }
            }
            // 流一停先把这一轮就地落成正史：时间戳当场出现、token 数（done 事件带了就一起）——
            // 原来要等整段正史（上百 KB）重拉回来才换上，末尾总卡一下（寻验 09-04）。出错那轮不落，照旧重拉。
            let local = (live?.finished == true && !Task.isCancelled) ? Self.materialize(live!) : []
            if !local.isEmpty { msgs.append(contentsOf: local) }
            rebuild()
            smoother?.invalidate(); smoother = nil
            live = nil
            sending = false
            // 对账：服务器落盘的才是正史；半截也存了（拉不到隔一秒再试一次）。行的身份按下标，条数对得上就不重排不闪
            if let id = conversationId {
                var conv = try? await GatewayAPI.conversation(id)
                if conv == nil { try? await Task.sleep(nanoseconds: 1_000_000_000); conv = try? await GatewayAPI.conversation(id) }
                if let conv {
                    msgs = conv.messages
                    renderFrom = min(renderFrom, max(0, msgs.count - 1))
                    lastPulse = Pulse(n: msgs.count, ts: msgs.last?.ts ?? "")
                    rebuild()
                } else { PushRegistrar.diag("chat: reload failed after stream") }
            }
        }
    }

    /// 这一轮的分段 → 正史条目（每段一条 assistant，工具胶囊挂在前一段上；最后一条带 usage）
    static func materialize(_ l: LiveTurn) -> [Msg] {
        var out: [Msg] = []
        var cur: Msg? = nil
        let now = TimeFmt.nowIso()
        for it in l.items {
            switch it {
            case .seg(let s):
                if let c = cur { out.append(c) }
                var m = Msg(role: "assistant", content: s.text, ts: now)
                m.thinking = s.thinking.isEmpty ? nil : s.thinking; m.thinkSecs = s.thinkSecs
                cur = m
            case .chip(let n, _):
                var m = cur ?? Msg(role: "assistant", content: "", ts: now)
                m.toolCalls = (m.toolCalls ?? []) + [ToolCall(function: .init(name: n, arguments: nil))]
                cur = m
            }
        }
        if let c = cur { out.append(c) }
        out = out.filter { !($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.cleanThinking.isEmpty || $0.toolCalls != nil }
        if var last = out.popLast() { last.usage = l.usage; out.append(last) }
        return out
    }

    /// 打字机循环（照网页 smoothTick，逐帧放字，追平即停）
    private var smoother: Timer? = nil
    /// 键盘正在起/收：打字机停一拍（09-15）。每帧重排整段正文和键盘那 0.25 秒的动画抢主线程，就是「克在回的时候收键盘、消息流下降慢」
    var kbBusy = false
    private func startSmoother() {
        guard smoother == nil else { return }
        // 30 帧/秒：60 帧时每帧都重解析、重排整段 markdown，字一长就掉帧；每帧多放一倍字，观感一样
        smoother = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, var l = self.live else { t.invalidate(); self?.smoother = nil; return }
                if self.kbBusy { return }
                if l.advance() { self.live = l } else { t.invalidate(); self.smoother = nil }
            }
        }
        RunLoop.main.add(smoother!, forMode: .common)
    }

    func stop() {
        guard let id = conversationId else { return }
        Task { await GatewayAPI.stop(id) }
    }

    /// 进后台：主动断开流。服务器见「她走了」就在克说完时整条推送到手机（和微信一样回来先看到通知），
    /// 回前台 pulse→load 把全文接回来。生成本身在服务器后台跑完，不会丢。
    func detach() {
        guard sending else { return }
        PushRegistrar.diag("chat: detach (background)")
        streamTask?.cancel()
        live = nil
        sending = false
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
    @State private var draft = Preview.on ? "" : (UserDefaults.standard.string(forKey: "draft.chat") ?? "")   // 没发出去的字留着，App 被刷掉再回来还在（寻验 09-04）
    @State private var pending: [String] = []
    @State private var plusOpen = false                 // 「+」菜单（拍照/相册）开着
    @State private var showWeb = false
    @State private var drawerOn = Preview.on && Preview.screen == "drawer"
    @State private var showMeal = false
    @State private var greetOn = !(Preview.on && Preview.screen != "greet")
    // 预览 letteralert：主页直接弹来信到站
    @State private var mealOk = false                 // 碗钮短暂变赤陶 ✓（照网页 1.2s）
    @StateObject private var lintel = LintelModel()
    @StateObject private var clawd = ClawdModel()
    @State private var atBottom = true
    @State private var farFromBottom = false
    // 开屏落定窗（09-21 寻：305 包冷启动还是不在底）：正史排上来后 6 秒内，只要内容长高、她没碰屏、没起键盘，就按真实内容高钉回底，
    // 不再猜是谁把内容撑高的（图片/语音条/字体……）；头几次钉底记一笔 diag 到服务器，方便查是谁长高的
    @State private var settleUntil = Date.distantPast
    @State private var settleLogs = 0
    @State private var loadAt = Date()
    @State private var dbg = ""
    @State private var composerFocused = false
    @ObservedObject private var rec = VoiceRecorder.shared   // 语音条录音（09-14）
    @ObservedObject private var trip = TripModel.shared      // 在路上（给克的导航，09-15）：门楣底下一条细行
    @State private var holdStarted = false
    struct VoiceDraft { let file: URL; let dur: Double; let orig: String }   // 松手后、发出前：音频＋识别原文（字在 draft 里，她可以改）
    @State private var voiceDraft: VoiceDraft? = nil
    @Environment(\.scenePhase) private var phase
    private let pulseTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    @State private var path: [Route] = {
        guard Preview.on else { return [] }
        switch Preview.screen {
        case "board", "boardpop", "boardreply", "letters", "letterread", "lettercompose", "seal", "sealdate", "lockpop", "lockerr": return [.board(openLetter: nil)]
        case "books", "booksup": return [.books]
        case "album", "albumbook", "albumlb": return [.album]
        case "mem": return [.mem]
        case "places", "tripsheet": return [.places]
        case "arch": return [.arch(day: "2026-09-02", q: nil, no: nil)]
        case "archhits": return [.arch(day: nil, q: "克", no: nil)]   // 检索命中页（像素字名字标签，09-15）
        case "archq": return [.arch(day: "2026-09-02", q: "安静", no: nil)]   // 带关键词进天页：右下角命中跳转胶囊（09-21）
        case "archno": return [.arch(day: "2026-09-02", q: nil, no: 1203)]   // #N 直跳的闪
        default: return []
        }
    }()
    @StateObject private var letters = LettersModel.shared
    @StateObject private var alerts = AlertsModel()
    @ObservedObject private var viewer = ImageViewer.shared   // 消息流/档案里点图 → 全屏看图（照网页 #imgView，盖在所有页之上）
    @State private var letterAlertOn = false      // 来信到站：进 Keep / 回前台有没看过的信就弹（寻定：不推手机）

    /// 页面切换照网页 #notesView.open{display:flex}：瞬间切、不滑不淡（寻定：干净利落）；左缘右滑＝退回上一页。
    var body: some View {
        ZStack {
            root
            ForEach(Array(path.enumerated()), id: \.offset) { i, r in
                Group {
                    switch r {
                    case .board(let openLetter): BoardScreen(onLogout: onLogout, onBack: pop, onWeb: { path.append(.web($0)) }, openLetter: openLetter)
                    case .books: BooksScreen(onBack: pop)
                    case .album: AlbumScreen(onBack: pop, onArchive: { d, n in path.append(.arch(day: d, q: nil, no: n)) })
                    case .mem: MemScreen(onBack: pop)
                    case .places: PlacesScreen(onBack: pop)
                    case .arch(let day, let q, let no): ArchiveScreen(onBack: pop, day: day, query: q, focusNo: no)
                    case .web(let link): WebShellScreen(onLogout: onLogout, onBack: pop, openDrawer: false, deepLink: link)
                    }
                }
                .zIndex(Double(100 + i))
                .background(EdgeSwipe(onBack: pop))
                .transaction { $0.animation = nil }
            }
            if let img = viewer.image {
                ImageViewerView(image: img, onClose: { viewer.image = nil }).zIndex(300).transaction { $0.animation = nil }
            }
        }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }

    @State private var kbUp = false
    @State private var wasAtBottom = true     // 键盘动之前在不在底（动的途中 atBottom 是过程值，不可信）
    @State private var kbAnimating = false
    @State private var userUp = false         // 克回话时她自己往上翻过：不再跟随到底，直到她回到底
    @State private var holdH: CGFloat = 0     // 录音浮层（小卡＋提示）的高；在底时列表底部垫这么多，把消息流抬到卡上面
    @State private var holdFromBottom = true  // 起录那一刻在不在底
    /// 键盘收着时才真正拨开关；键盘开着就等 keyboardDidHide 再拨
    private func syncAvoid() {
        let want = !(showMeal || drawerOn)
        if kbUp && KeyboardAvoid.shared.on != want { return }
        if KeyboardAvoid.shared.on != want { KeyboardAvoid.shared.on = want }
    }

    private var root: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    clawdProbe
                    messageList(proxy)
                    ClawdView(m: clawd).zIndex(5)
                    if farFromBottom && !atBottom && !kbAnimating && !rec.recording { jumpButton(proxy) }   // 键盘起收途中量到的「离底」是过程值，别闪钮
                    // A 版（寻 09-15 定回）：边说边出字的小卡浮在输入卡上方，卡下两侧「← 取消」「编辑 →」。
                    // 09-15 寻：卡和提示盖住后面的字无妨，但后面不能再垫一层底色挡字——所以是浮层不是兄弟行；
                    // 原本在底的话，消息流整个抬到卡上面（listContent 底部按卡高垫、随字长跟着钉底，见 holdH）
                    if rec.recording {
                        VStack(spacing: 0) {
                            LiveCard(rec: rec).padding(.bottom, 8)
                            HoldHints(rec: rec).padding(.bottom, 6)
                        }
                        .background(GeometryReader { g in
                            Color.clear.onAppear { holdH = g.size.height }.onChange(of: g.size.height) { holdH = $0 }
                        })
                        .zIndex(6)
                    }
                }
                .coordinateSpace(name: "clawdZone")
                .simultaneousGesture(TapGesture().onEnded { clawd.touched() })
            }
            composer
        }
        .background(Theme.bg.ignoresSafeArea())
        // 键盘让位交给系统（与键盘同曲线同时长）；吃吃笺/抽屉/别的页开着时把宿主的让位关掉，主页不动
        // 让位开关只在键盘收着时拨（键盘开着拨会整页重排——寻验 43「抽屉从天而降」）：
        // 键盘开着去拉抽屉/点吃吃 → 先收键盘，键盘收完再关让位；留言板等页开着时让位留着（浮卡靠它上移）
        .onChange(of: showMeal || drawerOn) { off in
            if off && kbUp { composerFocused = false } else { syncAvoid() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in kbUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in kbUp = false; syncAvoid() }
        .tint(Theme.scrollTint)                       // 光标、选中把手同滚动条色
        .simultaneousGesture(DragGesture(minimumDistance: 20, coordinateSpace: .global).onEnded { v in
            if v.startLocation.x < 24, v.translation.width > 60, !drawerOn { drawerOn = true }
        })   // 屏幕左缘右滑唤出抽屉
        // 「+」菜单：按「+」的锚点画在它正上方、左边对齐；点菜单外任何地方收起
        .overlayPreferenceValue(PlusAnchorKey.self) { a in
            if plusOpen, let a {
                GeometryReader { g in
                    let r = g[a]
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { withAnimation(.easeOut(duration: 0.15)) { plusOpen = false } }
                        // 系统款是从按钮上长出来、盖住按钮的：底边压到「+」下沿上 4 点，左边比「+」进 2 点
                        plusMenu
                            .frame(width: 176, height: max(0, r.maxY - 4), alignment: .bottomLeading)
                            .offset(x: r.minX + 2)
                            .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .zIndex(50)
            }
        }
        .onChange(of: composerFocused) { on in if on { plusOpen = false } }
        .overlay { if showMeal { MealSheet(shown: $showMeal, onSent: { line in
            model.addLocalPing(line)
            mealOk = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { mealOk = false }
        }).zIndex(60).ignoresSafeArea(.keyboard) } }
        .overlay {
            if letterAlertOn && !letters.unseen.isEmpty {
                LetterAlert(m: letters, onOpen: { e in letterAlertOn = false; path.append(.board(openLetter: e.id)) },
                            onLocked: { e in letterAlertOn = false; path.append(.board(openLetter: e.id)) }).zIndex(65)
            }
        }
        .onChange(of: letters.unseen.count) { n in if n == 0 { letterAlertOn = false } }
        .task { await letters.refresh(); if !letters.unseen.isEmpty, path.isEmpty, !Preview.on || Preview.screen == "letteralert" { letterAlertOn = true } }
        .overlay { if greetOn { GreetOverlay(shown: $greetOn).zIndex(70) } }
        .onChange(of: model.sending) { s in clawd.busy(s) }
        .onChange(of: model.live?.events ?? 0) { _ in
            if let l = model.live, l.items.contains(where: { if case .seg(let sg) = $0 { return sg.error != nil }; return false }) { clawd.alert() }
        }
        .task { await lintel.refresh() }
        .task { await trip.sync() }
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in Task { await lintel.refresh() } }
        .onAppear {
            model.onLogout = onLogout
            guard Preview.on else { return }
            switch Preview.screen {
            case "imgview":   // 看图器：拿预览里她发的那张
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let u = model.msgs.last(where: { $0.role == "user" && !($0.images ?? []).isEmpty })?.images?.first else { return }
                    Task { viewer.image = await StreamImageCache.load(u) }
                }
            case "voicehold", "voiceedit", "voicecancel":   // 语音条录音态截图：假装录着（字、秒数、音量），edit/cancel 再摆上对应手势的提示
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    rec.recording = true; rec.liveText = "今天雨停得早，我想去门口那棵树下坐一会儿"; rec.seconds = 6; rec.level = 0.6
                    rec.editHint = Preview.screen == "voiceedit"; rec.cancelHint = Preview.screen == "voicecancel"
                }
            case "voicedraft":   // 松手编辑后：字在输入框、小签在动作行
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    draft = "今天雨停得早，我想去门口那棵树下坐一会儿"
                    voiceDraft = VoiceDraft(file: FileManager.default.temporaryDirectory.appendingPathComponent("x.m4a"), dur: 6, orig: draft)
                }
            case "plusmenu":   // 「+」弹窗开着（拍照/相册）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { plusOpen = true }
            case "picker":     // 选图半屏抽屉升起来（模拟器自带几张样片；「album」这个名已归相册页）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { PhotoPickerBridge.shared.present(max: 4) { _ in } }
            case "kbup", "kbhide":   // 键盘：打几个字唤起；kbhide 再在 4 秒时收起（截图在 7 秒）
                draft = "试试看"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { composerFocused = true }
                if Preview.screen == "kbhide" { DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { composerFocused = false } }
            default: break
            }
        }
        .onReceive(pulseTimer) { _ in Task { await model.pulse() } }
        .onChange(of: phase) { p in
            if p == .active { Task { await model.pulse(); await letters.refresh(); if !letters.unseen.isEmpty, path.isEmpty, !Preview.on { letterAlertOn = true }
                                     await alerts.uvOnce(); await HealthSync.shared.syncOnActive(); await alerts.healthOnce(); await VoiceFixes.refresh() } }   // 「当天首开」也算回前台那次（App 常驻内存时 .task 不会再跑）
            if p == .background { model.detach() }
        }
        .onChange(of: draft) { d in if !Preview.on { UserDefaults.standard.set(d, forKey: "draft.chat") } }
        .fullScreenCover(isPresented: $showWeb) { WebShellScreen(onLogout: onLogout) }
        .overlay { DrawerView(shown: $drawerOn, unread: 0, onLogout: onLogout, onNavigate: { r in drawerOn = false; path.append(r) }).zIndex(50) }
        .overlay { if model.door?.closed == true { DoorView(model: model).zIndex(120) } }
        .overlay { if let s = alerts.current { StripPop(icon: s.icon, title: s.title, en: s.en, msg: s.msg, onClose: { alerts.dismiss() }).zIndex(60) } }
        .task {
            await alerts.poll(); await alerts.uvOnce()
            // 健康原生化（09-08）：首开问一次授权，然后早上档 + 当下快照；推完了「今天还没传健康数据」自然不弹
            PushRegistrar.diag("chat: task reached health")
            if await HealthSync.shared.requestAuth() { await HealthSync.shared.syncOnActive() }
            await alerts.healthOnce()
        }
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in Task { await alerts.poll() } }
        .onChange(of: model.sending) { s in if !s { Task { await alerts.balance() } } }   // 克说完话后查余额（照网页 done 时 refreshBalance）
    }

    /// 量 Clawd 活动区（消息区尺寸）
    private var clawdProbe: some View {
        GeometryReader { g in
            Color.clear.onAppear { clawd.layout(area: g.size, areaTop: g.frame(in: .global).minY) }
                .onChange(of: g.size) { sz in clawd.layout(area: sz, areaTop: g.frame(in: .global).minY) }
        }
    }

    /// 非懒 VStack（09-05 定）：懒列表的内容高是估算的，视口一变（键盘起收）它会把行撤掉重估——偏移明明在底、视口却空白（sim-77 截到），
    /// 末行滚不出来、钉底靠猜、起键盘露出中间的行全是它。主页只画最近两天（更早的按天手动加载），全排出来高度就是真的。
    /// 消息流本体拆成 MessageListBody（09-15 晚，收键盘那一两帧卡）：它只依赖 model 和 lift，键盘起收时 ChatScreen 这层的状态
    /// 变来变去（kbAnimating/wasAtBottom/kbUp/composerFocused），它不重算。这里只挂锚点和滚动观察。
    private var listContent: some View {
        MessageListBody(model: model, lift: rec.recording ? holdH : 0)
        .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("bottom") }   // 「到底」锚点不占行（占行会多出一格 spacing）
        .background(ScrollObserver(name: "chat") { y, ch, vh in
            let total = max(ch, 1)
            let gap = total - y - vh
            let far = gap > 40
            if farFromBottom != far { farFromBottom = far; atBottom = !far }   // 值没变就别碰 @State（碰一下＝整页重算一遍）
            // 09-15 晚寻：克回话时上滑还是怪——40 点以内松手会被钉回去。改记「她自己往上翻过」：手指在拖着且离底超 12 就记下，
            // 之后不再跟随，直到她回到底（跳底钮或自己滑回来，离底 < 4）
            if !userUp, let sv = ScrollObserver.view("chat"), sv.isTracking || sv.isDragging, gap > 12 { userUp = true }
            if userUp, gap < 4 { userUp = false }
            if Preview.on { dbg = String(format: "y=%.0f ch=%.0f vh=%.0f ", y, ch, vh) + ScrollObserver.note + " | " + ScrollObserver.trail.joined(separator: " ") }
            // 开屏落定窗：内容长高就钉回底（见 settleUntil）
            if Date() < settleUntil, gap > 1, !userUp, !kbAnimating, !composerFocused, path.isEmpty,
               let sv = ScrollObserver.view("chat"), !(sv.isTracking || sv.isDragging || sv.isDecelerating) {
                if settleLogs < 6 {
                    settleLogs += 1
                    PushRegistrar.diag(String(format: "cold: gap=%.0f y=%.0f ch=%.0f vh=%.0f t=+%.1fs", gap, y, ch, vh, Date().timeIntervalSince(loadAt)))
                }
                DispatchQueue.main.async { pinBottom() }
            }
        })
    }

    private func messageList(_ proxy: ScrollViewProxy) -> some View {
        ScrollView { listContent }
            .modifier(BottomAnchor())                 // iOS 18+：视口高一变（键盘起/收）底边锚定，和键盘同一条曲线，不再事后补滚
            .scrollIndicators(.visible)               // 系统原生指示条（染成赤陶，见 ScrollObserver）：能拖、拉到头会缩、和网页同款
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .topLeading) { if Preview.on { Text(dbg + " n=\(model.items.count)").font(Theme.ui(9)).foregroundColor(.red).padding(4) } }
            // 什么都没拉到（没缓存、两次都连不上）：一行小字，点一下再试（展示样式待寻审）
            .overlay {
                if model.items.isEmpty, model.live == nil, let e = model.lastError {
                    Text(e).font(Theme.round(12.5)).tracking(1).foregroundColor(Theme.muted)
                        .onTapGesture { Task { await model.load() } }
                }
            }
            .background(KeyboardDismisser())
            .onChange(of: model.items.count) { _ in if atBottom, !userUp { scrollBottom(proxy) } }
            .onChange(of: model.live?.items.count ?? 0) { _ in if atBottom, !userUp { scrollBottom(proxy) } }
            .onChange(of: model.sending) { s in if s { userUp = false } }   // 她自己发了一句＝回到底
            // 流式：字长出来就跟着到底（寻验：看不见流式）。键盘起收途中 atBottom 是过程值（视口在变），一帧量成「离底」
            // 跟随就断、之后再也不接上（寻验 131「等回复时收键盘，信息流卡在原地」）——动的那段按键盘前的 wasAtBottom 算
            // 09-15 寻：克生成期间她上滑会和自动到底打架——手指还在（拖着/惯性滑着）就不钉，松手离底超 40 后 atBottom 自己变假
            .onChange(of: model.live?.events ?? 0) { _ in
                if userUp { return }   // 她自己往上翻过就不再跟（09-15 晚）
                if let sv = ScrollObserver.view("chat"), sv.isTracking || sv.isDragging || sv.isDecelerating { return }
                if atBottom || (kbAnimating && wasAtBottom) { DispatchQueue.main.async { pinBottom() } }
            }
            // 录音浮层：起录时在底就记下来，卡长高（字多了）跟着钉底；收录把垫的高度撤掉、原本在底再钉一次
            .onChange(of: rec.recording) { on in
                if on { holdFromBottom = atBottom } else { holdH = 0; if holdFromBottom { DispatchQueue.main.async { pinBottom() } } }
            }
            .onChange(of: holdH) { _ in if rec.recording, holdFromBottom { DispatchQueue.main.async { pinBottom() } } }
            .onChange(of: model.sending) { s in if s { scrollBottom(proxy, animated: true) } }
            .onChange(of: model.loadTick) { _ in
                scrollBottom(proxy)
                loadAt = Date(); settleUntil = loadAt.addingTimeInterval(6); settleLogs = 0
            }
            // 图片从占位块换成真图（09-21 寻「进 Keep 不在最底」）：通知在改状态那刻发出、布局还没跑，atBottom 还是长高前的值；
            // 原本在底、她没在翻就等这一帧排完再按真实内容高钉底
            .onReceive(NotificationCenter.default.publisher(for: .keepImageLoaded)) { _ in
                guard atBottom, !userUp, path.isEmpty else { return }
                if let sv = ScrollObserver.view("chat"), sv.isTracking || sv.isDragging || sv.isDecelerating { return }
                DispatchQueue.main.async { pinBottom() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .keepThinkToggled)) { _ in
                // 末条的 thought 展开/折回改了内容高：原本在底就重新钉底，别留一截空（寻验 44）
                guard atBottom, let id = lastId else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
            }
            // 键盘跟随只能走 SwiftUI 自己的 scrollTo（UIKit 改 offset 会被它每帧写回）：原本在底，键盘来/走都钉着最后一行，
            // 时长取键盘的，曲线取系统键盘曲线的近似
            // iOS 18 起这两段不跑：底边锚定（BottomAnchor）由系统在布局里做，起/收都跟着键盘走（寻验 09-04：收键盘/发送后先掉一下再上来＝事后补滚的锅）
            // 所有版本都走这条（09-05 sim-78：iOS 18 的 sizeChanges 锚底对键盘让位这种内边距变化不起作用，起键盘偏移纹丝不动）；
            // 列表已是非懒 VStack、高度是真的，scrollTo 末行滚得准
            // 起键盘跟随在 ScrollObserver 里做（键盘动的那段逐帧钉底，见 Clawd.swift）：真机 diag 实证 SwiftUI 是把滚动区的框压矮（749→437）、
            // 偏移纹丝不动，iOS 18 的 sizeChanges 锚底没跟；SwiftUI 的 scrollTo 又不认让位（sim-78～80、构建 81 寻验「不跟着抬」），这里不再 scrollTo
            // iOS 16/17：键盘收完再钉一次：视口放高时懒列表的内容高是估的，滚到「底」底下会留一大截空、末行漂在上头（模拟器 sim-62 实证）——
            // 照冷启动的路子先滚到末行让它真排出来，再由 UIKit 按真实内容高钉底。键盘起时别这么钉（sim-63 实证：起的时候钉反而滚到半路）
            // 收完键盘：iOS 16/17 走老路（scrollTo 末行＋UIKit 按真实高钉底）；iOS 18 底边锚定已把大头做了，只让 SwiftUI 再滚到末行本身
            // 把它真排出来（本来就在底＝无感）——**不钉** UIKit 偏移：钉是按懒列表估算的内容高算的，估高了就滚到内容外头、整片白
            // （寻验 09-05 构建 72：刚开 App 点输入框直接大白屏，就是起键盘后那记补钉干的；记忆里 sim-63 早写过起键盘别钉）
            // 寻验 85：收完键盘一秒后消息流往下挪一点＝这里 scrollTo 末行把末行贴到视口底、把底下 10pt 的留白挤出去，
            // 而底边锚定/钳子随后又按真实内容高（含留白）拨回——两个「底」差 10pt。列表已是非懒 VStack，直接按真实内容高钉一次即可
            // 克正在回（sending）时收键盘一律回到底：她收键盘是为了看回复；下拉收键盘（interactively）那一下会把 wasAtBottom 拖成 false
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                guard wasAtBottom || model.sending, path.isEmpty, !showMeal, !drawerOn else { return }
                if #available(iOS 18, *) { pinBottom() } else { scrollBottom(proxy) }
                if model.sending { wasAtBottom = true; atBottom = true }
            }
            // 起完键盘还差一截就按真实内容高钉一次（列表是非懒 VStack、高度是真的；72 那回白屏是懒列表估算高的锅）
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                kbAnimating = false
                guard wasAtBottom, path.isEmpty, !showMeal, !drawerOn, farFromBottom else { return }
                pinBottom()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in wasAtBottom = atBottom; kbAnimating = true; model.kbBusy = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in wasAtBottom = atBottom; kbAnimating = true; model.kbBusy = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in kbAnimating = false; model.kbBusy = false }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in model.kbBusy = false }
            .onAppear {
                Task { await model.load() }
                // 截图场景 chips：工具行在预览对话靠前的位置，滚到顶把它露出来
                // 截图场景 md（09-21）：列表/标题样张在预览对话中段，滚到克那条「preview.json」处
                if Preview.on, ["chips", "md", "mdt"].contains(Preview.screen) {
                    for d in [3.0, 4.5] { DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                        guard let sv = ScrollObserver.view("chat"), !model.items.isEmpty else { return }
                        // 按目标行在列表里的位次粗估偏移（滚顶后它在视口外，sim-104）；md＝列表样张、mdt＝表格样张
                        let want = Preview.screen == "md" ? "preview.json" : Preview.screen == "mdt" ? "时段" : ""
                        let idx = model.items.firstIndex { if case .ai(_, let m, _) = $0.item {
                            return want.isEmpty ? !(m.toolCalls ?? []).isEmpty : (m.content ?? "").contains(want)
                        } else { return false } } ?? 0
                        let y = max(0, sv.contentSize.height * CGFloat(idx) / CGFloat(model.items.count) - (want.isEmpty ? 240 : 200))
                        sv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    } }
                }
            }
    }

    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        Button { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
            Image("chev").renderingMode(.template).resizable().frame(width: 20, height: 20)
                .foregroundColor(Theme.jumpArrow)
                .frame(width: 38, height: 38)
                .background(Theme.jumpBg, in: Circle())
                .overlay(Circle().stroke(Theme.jumpRing, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.10), radius: 9, y: 6)
                .shadow(color: Color.black.opacity(0.14), radius: 4, y: 2)
        }
        .padding(.bottom, 10)
        .transition(.opacity.combined(with: .scale(scale: 0.82)))
    }


    /// 顶栏（照网页 header）：左上角展开钮（42px 圆、发丝圈、三道 16×2 靠左）| 门楣列 | 吃饭钮。在路上时底下多一条细行（09-15）。
    private var header: some View {
        VStack(spacing: 0) {
            headerRow
            if Trip.enabled, let t = trip.current {
                TripStrip(trip: t, onTap: { path.append(.places) }).padding(.leading, 54).padding(.trailing, 16).padding(.bottom, 6)
            }
        }
        .background(Theme.bg)
        .zIndex(30)
    }
    private var headerRow: some View {
        HStack(spacing: 0) {
            Button { drawerOn = true } label: {
                VStack(alignment: .leading, spacing: 4) {   // 照网页：三道 16/16/11 × 2，圆头，八成不透明
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text.opacity(0.8)).frame(width: 16, height: 2)
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text.opacity(0.8)).frame(width: 16, height: 2)
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text.opacity(0.8)).frame(width: 11, height: 2)
                }
                .padding(.leading, 12)
                .frame(width: 42, height: 42, alignment: .leading)
                .background(Theme.menuFill, in: Circle())
                .overlay(Circle().stroke(Theme.hairRing, lineWidth: 1.5))
                .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
                .shadow(color: Color.black.opacity(0.08), radius: 14, y: 8)
            }
            .buttonStyle(.plain)
            .frame(width: 42, height: 42)
            LintelColumn(m: lintel)
            Button { showMeal = true } label: {
                Group {
                    if mealOk { Text("✓").font(Theme.ui(17, weight: .bold)).foregroundColor(Theme.accent) }
                    else { Image("bowl").renderingMode(.template).resizable().frame(width: 20, height: 20).foregroundColor(Theme.muted) }
                }.frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    // 行距/行视图/直播段的画法都在 MessageList.swift 的 MessageListBody 里（09-15 晚拆出）

    /// 克的选项卡：最末一条是他的话且带 [reply: …]、他没在说话 → 摊在输入卡上方（她一回话就自然撤下）
    private var activeReplies: (id: String, options: [String])? {
        guard model.live == nil, !model.sending, let last = model.items.last, case .ai(_, let m, _) = last.item else { return nil }
        let opts = Replies.split(m.content ?? "").options
        guard !opts.isEmpty else { return nil }
        return (last.id, opts)
    }

    /// 输入卡（照网页 #inputbox）：composer 底、1.5px 发丝圈、26 圆角、两层阴影；上排文字，下排＋与发送。
    /// 克在问的时候（09-13 寻定，照 claude.ai）：选项卡从卡顶长出来，输入行留在底下当「自己说」
    private var composer: some View {
        VStack(spacing: 6) {
            if let r = activeReplies {
                ReplyCard(options: r.options, onPick: { model.send(text: $0, images: []) })
            }
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pending.enumerated()), id: \.offset) { i, u in
                            ZStack(alignment: .topTrailing) {
                                DataImage(src: u, maxW: 64, maxH: 64, radius: 12)
                                    .onTapGesture { Task { ImageViewer.shared.image = await StreamImageCache.load(u) } }   // 09-21 寻：选中的图点开看大图
                                Button { pending.remove(at: i) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                        .frame(width: 18, height: 18).background(Color.black.opacity(0.55), in: Circle())
                                }.buttonStyle(.plain).offset(x: 4, y: -4)
                            }
                        }
                    }.padding(.horizontal, 2).padding(.top, 6)   // 给右上角的 × 留出头
                }
            }
            // 语音条（09-14 夜寻定）：输入框没唤起、没字的时候**长按输入行**开录，输入行原地换成音量条＋秒数（卡不变高），
            // 字在上方的小卡里边说边长；上滑取消；松手字落进这里，改不改都行，点 ↑ 发。长按由一层透明盖子接（不抢短按：短按仍是唤起输入）
            ZStack {
                Composer(text: $draft, focused: $composerFocused, placeholder: activeReplies == nil ? "Chat with…" : "Reply…")      // 字同她的气泡（Lora→宋体）、行距 1.5、光标赤陶 40%
                    .opacity(rec.recording ? 0 : 1)
                    // 盖子挂成 overlay（和输入框一样大）——构建 226 把它当 ZStack 兄弟放，Color.clear 把能占的都占了，输入卡撑成半屏（寻验）
                    .overlay {
                        if !composerFocused && draft.isEmpty && voiceDraft == nil && !model.sending {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { composerFocused = true }
                                .gesture(LongPressGesture(minimumDuration: 0.2).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))   // 09-15 寻：0.35 太长
                                    .onChanged { v in
                                        switch v {
                                        case .second(true, let drag):
                                            if !holdStarted { holdStarted = true; startHold() }
                                            let m = Self.holdMode(drag?.translation ?? .zero)
                                            let c = m == .cancel, e = m == .edit
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
                // 选图走自己弹的 PHPicker：弹出前把 tint 钉成赤陶（寻验 09-04：SwiftUI 的 PhotosPicker 头一回弹出来右上角是系统蓝）
                // 09-21 寻：「+」不再直接弹相册（常误触）——弹「拍照」「相册」两项。
                // 二回：系统菜单（Menu）宽度定死 250，两个短词右边空一大截、改不了；popover 气泡寻嫌不好看——
                // 照系统菜单的样子自己画一块（圆角 13、毛玻璃、44 高一行、字左图标右、细线分隔、无箭头），只把宽收到内容宽，
                // 挂在「+」正上方（锚点走 anchorPreference，overlay 画在最外层，不被输入卡裁）
                Button {
                    composerFocused = false
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { plusOpen = true }
                } label: {
                    Image("plus").renderingMode(.template).resizable().frame(width: 17, height: 17).foregroundColor(Theme.text)
                        .frame(width: 36, height: 36).background(Theme.attachBg, in: Circle())
                }
                .buttonStyle(.plain)
                .anchorPreference(key: PlusAnchorKey.self, value: .bounds) { $0 }
                .padding(.leading, -4)
                // 松手后的语音小签：麦克风＋秒数，× 丢掉（字和音频一起丢）
                if let vd = voiceDraft {
                    HStack(spacing: 6) {
                        Image("mic").renderingMode(.template).resizable().frame(width: 12, height: 12).foregroundColor(Theme.text)
                        Text("\(Int(vd.dur.rounded()))″").font(Theme.mono(12.5, weight: .medium)).foregroundColor(Theme.text)
                        Button { discardVoiceDraft() } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.muted).frame(width: 18, height: 18)
                        }.buttonStyle(.plain)
                    }
                    .padding(.leading, 10).padding(.trailing, 4).frame(height: 28)
                    .background(Theme.userBubble, in: Capsule())
                }
                Spacer()
                Button {
                    if model.sending { model.stop() } else if canSend { sendNow() }
                } label: {
                    Group {
                        if model.sending {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.text).frame(width: 12, height: 12)
                        } else if canSend {
                            Text("↑").font(Theme.ui(17, weight: .medium)).foregroundColor(.white)   // 照网页 #send .arr
                        } else {
                            Image("wav").renderingMode(.template).resizable().frame(width: 25, height: 25)
                                .foregroundColor(Theme.sendIdleFg)                              // 网页那份 SVG 原件
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(model.sending ? Theme.attachBg : (canSend ? Theme.accent : Theme.sendIdle), in: Circle())
                    .animation(.easeInOut(duration: 0.2), value: canSend)
                }
                .buttonStyle(.plain)   // 不用 .disabled：plain 样式会把禁用态压灰（寻验：黑钮变灰）
            }
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 10, trailing: 14))   // 上面拉高一点（寻验 41）
        // 投影只挂在卡底那张纸上（挂整张卡会给里面的 UIKit 输入框各描一圈晕）
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.composer)
            .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
            .shadow(color: Color.black.opacity(0.09), radius: 19, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.hairRing, lineWidth: 1.5))
        // 整张卡都算输入框（寻验 85）：点卡上文字以外的空白不收键盘，反而把焦点给输入框——选字时误触上沿不再退出
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { if !composerFocused { composerFocused = true } }
        .background(GeometryReader { g in
            Color.clear.onAppear { KeyboardDismisser.keep["composer"] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { r in KeyboardDismisser.keep["composer"] = r }
        })
        .padding(.horizontal, 10).padding(.top, 0).padding(.bottom, 8)   // 消息区到输入卡＝网页 #messages padding-bottom 10，别再叠
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty }
    enum PlusAction { case camera, album }
    /// 「+」菜单（照寻 09-21 发来的 iOS 26 系统菜单截图）：赤陶色图标在左、字跟在后、一行 56 高、没有分隔线、
    /// 整块圆角 28、近白的毛玻璃底、软投影；「相册」在上「拍照」在下（系统把离按钮近的排下面）。只把宽收到内容宽（176）。
    private var plusMenu: some View {
        VStack(spacing: 0) {
            plusRow("相册", "photo.on.rectangle") { pick(.album) }
            plusRow("拍照", "camera") { pick(.camera) }
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
    private func pick(_ a: PlusAction) {
        withAnimation(.easeOut(duration: 0.15)) { plusOpen = false }
        switch a {
        case .camera: CameraBridge.shared.present { img in Task { await addImages([img]) } }
        case .album: PhotoPickerBridge.shared.present(max: 4 - pending.count) { imgs in Task { await addImages(imgs) } }
        }
    }
    /// 长按输入行：问一次权限（只第一次会弹），起录
    private func startHold() {
        guard !model.sending, !model.transcribing, !rec.recording else { return }
        composerFocused = false
        Task {
            if await rec.requestPermission() {
                if !holdStarted { return }                       // 权限弹窗期间手已经松了
                if !rec.start() { alerts.push(AlertsModel.Strip(icon: "mic", title: "录不了音", en: false, msg: "麦克风起不来，再试一次。", kind: "voice")) }
            } else {
                alerts.push(AlertsModel.Strip(icon: "mic", title: "没有麦克风权限", en: false, msg: "到 设置 → Keep → 麦克风 打开，就能按住说话了。", kind: "voice"))
            }
        }
    }
    enum HoldMode { case send, edit, cancel }
    /// 手指位置→意图（A 版）：左滑 60 取消（上滑也算），右滑 60 编辑，其余松手就发
    private static func holdMode(_ t: CGSize) -> HoldMode { (t.width < -60 || t.height < -60) ? .cancel : (t.width > 60 ? .edit : .send) }
    /// 松手：取消＝作废；不到 1 秒＝当没录；发＝立刻传音频＋发出；编辑＝字落进输入框、键盘升起、留一个语音小签，等她点 ↑。
    /// 没听出字（识别没连上）时不能直接发，退成编辑态让她打字补
    private func endHold(_ mode: HoldMode) {
        guard rec.recording else { return }
        if mode == .cancel { rec.cancel(); UIImpactFeedbackGenerator(style: .light).impactOccurred(); return }
        Task {
            guard let r = await rec.finish() else { UIImpactFeedbackGenerator(style: .light).impactOccurred(); return }
            if let old = voiceDraft { try? FileManager.default.removeItem(at: old.file) }
            if mode == .send && !r.2.isEmpty {
                let imgs = pending; pending = []   // 09-21 寻：已选的图随语音一起走
                model.sendVoice(file: r.0, dur: r.1, text: r.2, orig: rec.rawText, images: imgs)   // orig＝识别原文（字典改之前），学编辑用
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                return
            }
            voiceDraft = VoiceDraft(file: r.0, dur: r.1, orig: rec.rawText)
            draft = r.2
            if r.2.isEmpty { alerts.push(AlertsModel.Strip(icon: "mic", title: "没听出字", en: false, msg: (rec.asrState.isEmpty ? "" : rec.asrState + "，") + "可以直接打字补上，音频还在。", kind: "voice")) }
            composerFocused = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    private func discardVoiceDraft() {
        if let vd = voiceDraft { try? FileManager.default.removeItem(at: vd.file) }
        voiceDraft = nil; draft = ""
    }

    private func sendNow() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = pending
        draft = ""; pending = []
        composerFocused = false
        if let vd = voiceDraft, !t.isEmpty {
            voiceDraft = nil
            model.sendVoice(file: vd.file, dur: vd.dur, text: t, orig: vd.orig, images: imgs)   // 09-21 寻：带图也是语音条，图一起走
            return
        }
        if let vd = voiceDraft { try? FileManager.default.removeItem(at: vd.file); voiceDraft = nil }   // 字全删了只剩图：当普通消息发，音频不要了
        model.send(text: t, images: imgs)
    }

    /// 列表末尾的那一行（懒列表的「到底」锚点按估算高度定位，最后一行没排出来就停在它上头——寻验：最后一条克的话总看不见）
    private var lastId: String? {
        if model.live != nil { return "live" }
        return model.items.last?.id
    }
    /// 到底：先让 SwiftUI 滚到最后一行本身（把它真排出来），再由 UIKit 按真实内容高精确钉底（含底部 10 留白）。
    /// 补钉只在真的没到底时才动（寻验：开屏后界面上下弹几下＝反复重滚）。
    private func scrollBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        // 一律滚到「bottom」锚（列表底部留白之下）：滚末行会把底下 10pt 留白挤出去，随后 pinBottom 又按真实内容高拨回，
        // 开屏就是 1542→1552→1542→1552 那几下（sim-97 轨迹实录；寻早前「界面弹几下」）。列表已是非懒 VStack，锚点位置是真的
        let go = { proxy.scrollTo("bottom", anchor: .bottom) }
        if animated { withAnimation(.easeOut(duration: 0.25)) { go() } } else { go() }
        for d in [0.05, 0.2, 0.5, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + d) { pinBottom() } }
    }
    private func pinBottom() {
        guard let sv = ScrollObserver.view("chat") else { return }
        let inset = sv.adjustedContentInset
        let maxY = sv.contentSize.height - sv.bounds.height + inset.bottom
        if maxY > -inset.top, abs(sv.contentOffset.y - maxY) > 1 { sv.setContentOffset(CGPoint(x: 0, y: maxY), animated: false) }
    }

    /// 选图 → 长边 1568 的 jpeg dataURL（Anthropic 最优尺寸），最多 4 张。
    private func addImages(_ imgs: [UIImage]) async {
        for ui in imgs {
            guard pending.count < 4 else { break }
            let L: CGFloat = 1568
            let s = min(1, L / max(ui.size.width, ui.size.height))
            let size = CGSize(width: (ui.size.width * s).rounded(), height: (ui.size.height * s).rounded())
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
            let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
            if let jpg = img.jpegData(compressionQuality: 0.85) {
                pending.append("data:image/jpeg;base64," + jpg.base64EncodedString())
            }
        }
    }
}

/// 「+」按钮在屏上的位置（给自画菜单定位用）
struct PlusAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// 视口尺寸一变就把底边锚住（iOS 18 起有这个开关）：键盘起/收时最后一行跟着键盘走，和系统同一条曲线
struct BottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) { content.defaultScrollAnchor(.bottom, for: .sizeChanges) } else { content }
    }
}

/// 系统选图器自己弹（PHPicker 是别的进程画的远程视图，只认弹出前钉在它 view 上的 tintColor）
@MainActor
/// 相机（09-21 寻：在 Keep 里直接拍一张给克）：系统相机整页弹出，拍完回一张 UIImage；模拟器没相机就什么都不做
final class CameraBridge: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    static let shared = CameraBridge()
    private var done: ((UIImage) -> Void)? = nil
    func present(done: @escaping (UIImage) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera), let top = PhotoPickerBridge.topVC() else { return }
        let p = UIImagePickerController()
        p.sourceType = .camera; p.cameraCaptureMode = .photo; p.delegate = self
        p.view.tintColor = Theme.uiScrollTint
        self.done = done
        top.present(p, animated: true)
    }
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        let cb = done; done = nil
        if let ui = (info[.editedImage] ?? info[.originalImage]) as? UIImage { cb?(ui) }
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done = nil; picker.dismiss(animated: true) }
}

final class PhotoPickerBridge: NSObject, PHPickerViewControllerDelegate {
    static let shared = PhotoPickerBridge()
    private var done: (([UIImage]) -> Void)? = nil
    func present(max: Int, done: @escaping ([UIImage]) -> Void) {
        guard max > 0, let top = Self.topVC() else { return }
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.selectionLimit = max; cfg.filter = .images
        // 09-22 寻：半屏时系统把「添加」藏在顶栏里，非拉到全屏才能确定——改成嵌入式：选择器塞进我们自己的容器，
        // 每勾一张就回调（continuous），顶上自己画「取消 / 完成(n)」，半屏就能确定。iOS 17 起才有嵌入式，老系统照旧整页弹
        if #available(iOS 17, *) {
            cfg.selection = .continuousAndOrdered
            cfg.disabledCapabilities = [.selectionActions]
            cfg.edgesWithoutContentMargins = .all
            let p = PHPickerViewController(configuration: cfg)
            p.delegate = self
            top.view.window?.tintColor = Theme.uiScrollTint
            p.view.tintColor = Theme.uiScrollTint
            self.done = done
            self.current = []
            let host = EmbeddedPickerVC(picker: p, onCancel: { [weak self] in
                self?.done = nil; self?.current = []
            }, onDone: { [weak self] in
                guard let self else { return }
                let cb = self.done; self.done = nil
                let results = self.current; self.current = []
                Task { @MainActor in
                    var imgs: [UIImage] = []
                    for r in results { if let ui = await Self.load(r.itemProvider) { imgs.append(ui) } }
                    cb?(imgs)
                }
            })
            // 09-22 寻二回：系统 sheet 不满屏时（iOS 26 起）自带浮起卡片样——两侧、底部都离开屏幕边还带描边，
            // 从外面改不掉；改成自己画贴边抽屉（四分之三高、只圆上角、升降/下拉自己动画）
            host.modalPresentationStyle = .overFullScreen
            top.present(host, animated: false) {
                p.view.tintColor = Theme.uiScrollTint.withAlphaComponent(0.99)
                p.view.tintColor = Theme.uiScrollTint
            }
            return
        }
        let p = PHPickerViewController(configuration: cfg)
        p.delegate = self
        // 勾勾、右上角「完成」都用赤陶（寻：橙色好看，不要系统蓝）。远程视图连上来有先有后：
        // 弹出前钉一次，弹完再拨一次（换个值再换回来，逼它把 tint 再发一遍）——寻验 09-04 二回：只钉一次时头一回还是蓝
        top.view.window?.tintColor = Theme.uiScrollTint
        p.view.tintColor = Theme.uiScrollTint
        self.done = done
        // 09-21 寻：选图页整页升起来又慢又重——改成半屏抽屉（同网页里那种），往上拖到全屏；相册的格子照旧
        if let sp = p.sheetPresentationController {
            sp.detents = [.medium(), .large()]
            sp.selectedDetentIdentifier = .medium
            sp.prefersGrabberVisible = true
        }
        top.present(p, animated: true) {
            p.view.tintColor = Theme.uiScrollTint.withAlphaComponent(0.99)
            p.view.tintColor = Theme.uiScrollTint
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                p.view.tintColor = Theme.uiScrollTint.withAlphaComponent(0.99)
                p.view.tintColor = Theme.uiScrollTint
            }
        }
    }
    /// 嵌入式下每勾一张系统就回调一次，这里只记住当前勾了什么，等她点「完成」再取
    private var current: [PHPickerResult] = []
    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        Task { @MainActor in
            if #available(iOS 17, *), let host = picker.parent as? EmbeddedPickerVC {
                self.current = results
                host.setCount(results.count)
                return
            }
            picker.dismiss(animated: true)
            let cb = self.done; self.done = nil
            var imgs: [UIImage] = []
            for r in results { if let ui = await Self.load(r.itemProvider) { imgs.append(ui) } }
            cb?(imgs)
        }
    }
    private static func load(_ ip: NSItemProvider) async -> UIImage? {
        guard ip.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { c in
            ip.loadObject(ofClass: UIImage.self) { o, _ in c.resume(returning: o as? UIImage) }
        }
    }
    static func topVC() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var vc = (scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first)?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

/// 嵌入式选图容器：顶栏「取消 ｜ 相册 ｜ 完成」自己画，下面整块是系统选择器（勾选格子照旧系统的）
@available(iOS 17, *)
final class EmbeddedPickerVC: UIViewController, UIGestureRecognizerDelegate {
    private let picker: PHPickerViewController
    private let onCancel: () -> Void
    private let onDone: () -> Void
    private let doneBtn = UIButton(type: .system)
    init(picker: PHPickerViewController, onCancel: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.picker = picker; self.onCancel = onCancel; self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// 自己画的抽屉：dim 是后面那层暗、panel 是贴边的四分之三高面板（只圆上角）
    private let dim = UIView()
    private let panel = UIView()
    private var panelHeight: NSLayoutConstraint?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dim.alpha = 0
        dim.translatesAutoresizingMaskIntoConstraints = false
        dim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTap)))
        view.addSubview(dim)
        panel.backgroundColor = UIColor(Theme.bg)
        panel.layer.cornerRadius = 36
        panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panel.clipsToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        // 横线：寻 09-22 定留（选 2），但要照参考图的粗细长度——约 58×3、离顶 8，浅灰
        let grab = UIView()
        grab.backgroundColor = Theme.uiDyn(0xC9C9CD, 0x5A5A5E)
        grab.layer.cornerRadius = 1.5
        grab.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(grab)
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(bar)
        // 下拉关（＝取消）：手势挂面板上，但只认从头部（横线＋圆钮那 84）起手的，格子区留给选择器自己滚
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        panel.addGestureRecognizer(pan)
        // 09-22 寻发来系统全屏态的头做参考：左圆圈 ✕、右圆圈 ✓（勾了赤陶、没勾灰），中间那些字和「照片／精选集」她说没用，不画
        // 两只都是 iOS 26+ 的玻璃圆钮（寻 09-22 二回：「注意看，叉叉勾勾都是玻璃UI」）；老系统兜底平圆
        let cancel = UIButton(type: .system)
        Self.style(cancel, symbol: "xmark", size: 17, weight: .regular, fill: nil, fg: Theme.uiText)   // 09-22 寻：叉 18 太大→16 又小了一点→17
        cancel.addAction(UIAction { [weak self] _ in self?.cancelTap() }, for: .touchUpInside)
        doneBtn.addAction(UIAction { [weak self] _ in self?.doneTap() }, for: .touchUpInside)
        setCount(0)
        for b in [cancel, doneBtn] { b.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(b) }
        addChild(picker)
        picker.view.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(picker.view)
        picker.didMove(toParent: self)
        // 09-22 寻二回：系统选择器自己顶上有 16 的灰内距（edgesWithoutContentMargins 关不掉）——把它顶到圆钮底下，
        // 再用一条和面板同色的 16 高盖条压住：圆钮到格子正好留 16，而且是面板色不是灰
        let cover = UIView()
        cover.backgroundColor = UIColor(Theme.bg)
        cover.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(cover)
        let h = panel.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.75)
        panelHeight = h
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: view.topAnchor), dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor), dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // 面板：贴两侧贴底，可见部分（底部安全区以上）占安全区高的四分之三
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            h,
            grab.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            grab.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            grab.widthAnchor.constraint(equalToConstant: 58), grab.heightAnchor.constraint(equalToConstant: 3),
            bar.topAnchor.constraint(equalTo: panel.topAnchor, constant: 26),
            bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 42),
            cancel.widthAnchor.constraint(equalToConstant: 42), cancel.heightAnchor.constraint(equalToConstant: 42),
            cancel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 18),
            cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            doneBtn.widthAnchor.constraint(equalToConstant: 42), doneBtn.heightAnchor.constraint(equalToConstant: 42),
            doneBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -18),
            doneBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            picker.view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            picker.view.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            picker.view.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            picker.view.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            cover.topAnchor.constraint(equalTo: bar.bottomAnchor),
            cover.heightAnchor.constraint(equalToConstant: 16),
            cover.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        panelHeight?.constant = view.safeAreaInsets.bottom   // 面板延到屏幕底，底部安全区那截算额外的
    }
    /// 升起：面板先藏在屏幕底下，出现后弹上来；暗层同步淡入
    private var shown = false
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.layoutIfNeeded()
        panel.transform = CGAffineTransform(translationX: 0, y: panel.bounds.height)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !shown else { return }
        shown = true
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.4) {
            self.panel.transform = .identity
            self.dim.alpha = 1
        }
    }
    /// 落下：面板滑回屏幕底，暗层淡出，然后不带动画地撤掉这个 VC
    private func slideOut() {
        UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseIn]) {
            self.panel.transform = CGAffineTransform(translationX: 0, y: self.panel.bounds.height)
            self.dim.alpha = 0
        } completion: { _ in self.dismiss(animated: false) }
    }
    @objc private func dimTap() { cancelTap() }
    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let dy = g.translation(in: view).y
        switch g.state {
        case .changed:
            panel.transform = CGAffineTransform(translationX: 0, y: max(0, dy))
        case .ended, .cancelled:
            if dy > panel.bounds.height / 3 || g.velocity(in: view).y > 900 {
                cancelTap()
            } else {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) { self.panel.transform = .identity }
            }
        default: break
        }
    }
    /// 没勾：灰底玻璃白勾；勾了：赤陶玻璃白勾（参考图两态，寻 09-22 三回：「参考图是灰底白勾哦」）
    private static let grayGlass = Theme.uiDyn(0xCFCFCF, 0x4A4A47)
    private var count = 0
    func setCount(_ n: Int) {
        count = n
        // 不走 isEnabled（系统会把禁用态的勾压暗，寻要的是纯白勾），没勾时点了不做事
        Self.style(doneBtn, symbol: "checkmark", size: 18, weight: .medium, fill: n > 0 ? Theme.uiScrollTint : Self.grayGlass, fg: .white)   // 09-22 寻：20 稍大→18
    }
    /// fill 为 nil＝素玻璃（✕ 用）；给了颜色＝实色玻璃
    private static func style(_ b: UIButton, symbol: String, size: CGFloat, weight: UIImage.SymbolWeight, fill: UIColor?, fg: UIColor) {
        let img = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
        if #available(iOS 26, *) {
            var c: UIButton.Configuration = fill == nil ? .glass() : .prominentGlass()
            c.cornerStyle = .capsule
            c.image = img
            c.baseForegroundColor = fg
            if let fill { c.baseBackgroundColor = fill }
            b.configuration = c
            b.tintColor = fill ?? fg
        } else {
            b.setImage(img, for: .normal)
            b.tintColor = fg
            b.backgroundColor = fill ?? UIColor(Theme.menuFill)
            b.layer.cornerRadius = 21
        }
    }
    private var settled = false
    private func cancelTap() { guard !settled else { return }; settled = true; onCancel(); slideOut() }
    private func doneTap() { guard count > 0, !settled else { return }; settled = true; onDone(); slideOut() }
    /// 只认从头部（横线＋圆钮区，顶上 84）起手的下拉；格子区的手势归选择器
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let p = g as? UIPanGestureRecognizer else { return true }
        return p.location(in: panel).y < 84 && p.velocity(in: panel).y > 0
    }
    /// 手指把抽屉拖下去关掉＝取消
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !settled { settled = true; onCancel() }
    }
}

/// 网页壳全屏（书架/相册/留言板/记忆/档案等长尾页先留网页），顶上一条「‹ 聊天」回来。
struct WebShellScreen: View {
    let onLogout: () -> Void
    var onBack: () -> Void = {}
    var openDrawer = true
    var deepLink = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBack(); dismiss() } label: {
                    BackChevron()
                }.buttonStyle(.plain).padding(.leading, -8)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.bg)
            ShellView(token: Keychain.token ?? "", openDrawer: openDrawer, deepLink: deepLink, onLogout: { onBack(); dismiss(); onLogout() })
                .ignoresSafeArea(edges: .bottom)
                .ignoresSafeArea(.keyboard)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}


/// 发送键无字态的声波（照网页 SVG viewBox 0 0 36 36，六根圆头竖线，铺满 36 圆）
struct WaveIcon: View {
    var color: Color
    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 36
            var p = Path()
            for (x, y0, y1) in [(5.37, 16.24, 19.77), (10.38, 13.32, 22.68), (15.39, 9.13, 26.87),
                                (20.4, 13.32, 22.68), (25.46, 10.59, 25.42), (30.47, 16.24, 19.77)] {
                p.move(to: CGPoint(x: x * k, y: y0 * k)); p.addLine(to: CGPoint(x: x * k, y: y1 * k))
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2.3 * k, lineCap: .round))
        }
        .frame(width: 36, height: 36)
    }
}
