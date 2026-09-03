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
    /// 打字机一帧：积压越多每帧放越多（约 0.4s 追平）。放了字返回 true。
    mutating func advance() -> Bool {
        var s = seg
        let n = s.text.count
        guard s.shown < n else { return false }
        s.shown = min(n, s.shown + max(1, Int((Double(n - s.shown) / 24).rounded())))
        seg = s; events += 1
        return true
    }

    mutating func apply(_ ev: GatewayAPI.Event) {
        events += 1
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
        do {
            guard let id = try await GatewayAPI.latestConversationId() else { return }
            let conv = try await GatewayAPI.conversation(id)
            conversationId = conv.id
            msgs = conv.messages
            renderFrom = Self.startOfLastDays(msgs, days: 2)
            rebuild()
            lastPulse = Pulse(n: msgs.count, ts: msgs.last?.ts ?? "")
            loadTick += 1
            await refreshDoor()
        } catch GatewayAPI.Failure.unauthorized {
            onLogout()
        } catch {
            lastError = "连不上"
        }
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
        sending = true; lastError = nil; lastEventAt = Date()
        msgs.append(Msg(role: "user", content: text, ts: TimeFmt.nowIso(), images: images.isEmpty ? nil : images))
        rebuild()
        live = LiveTurn()
        PushRegistrar.diag("chat: send")
        streamTask = Task {
            do {
                for try await ev in GatewayAPI.chat(conversationId: conversationId, message: text, images: images) {
                    lastEventAt = Date()
                    if case .start(let cid) = ev, !cid.isEmpty { conversationId = cid; PushRegistrar.diag("chat: start") }
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
            // 对账：服务器落盘的才是正史；半截也存了（拉不到隔一秒再试一次）
            if let id = conversationId {
                var conv = try? await GatewayAPI.conversation(id)
                if conv == nil { try? await Task.sleep(nanoseconds: 1_000_000_000); conv = try? await GatewayAPI.conversation(id) }
                if let conv {
                    msgs = conv.messages
                    renderFrom = min(renderFrom, max(0, msgs.count - 1))
                    lastPulse = Pulse(n: msgs.count, ts: msgs.last?.ts ?? "")
                } else { PushRegistrar.diag("chat: reload failed after stream") }
            }
            rebuild()
            smoother?.invalidate(); smoother = nil
            live = nil
            sending = false
        }
    }

    /// 打字机循环（照网页 smoothTick，逐帧放字，追平即停）
    private var smoother: Timer? = nil
    private func startSmoother() {
        guard smoother == nil else { return }
        smoother = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, var l = self.live else { t.invalidate(); self?.smoother = nil; return }
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
    @State private var draft = ""
    @State private var pending: [String] = []
    @State private var picks: [PhotosPickerItem] = []
    @State private var showWeb = false
    @State private var drawerOn = Preview.on && Preview.screen == "drawer"
    @State private var showMeal = false
    @State private var greetOn = !(Preview.on && Preview.screen != "greet")
    // 预览 letteralert：主页直接弹来信到站
    @State private var mealEchoes: [MealEcho] = []   // 吃吃就地回显；正牌小纸条进正史后自动顶替
    @State private var mealOk = false                 // 碗钮短暂变赤陶 ✓（照网页 1.2s）
    struct MealEcho: Identifiable { let id = UUID(); let line: String; let at: Date }
    @StateObject private var lintel = LintelModel()
    @StateObject private var clawd = ClawdModel()
    @State private var atBottom = true
    @State private var farFromBottom = false
    @State private var dbg = ""
    @State private var composerFocused = false
    @Environment(\.scenePhase) private var phase
    private let pulseTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    @State private var path: [Route] = {
        guard Preview.on else { return [] }
        switch Preview.screen {
        case "board", "boardpop", "boardreply", "letters", "letterread", "lettercompose", "seal", "lockpop": return [.board(openLetter: nil)]
        case "books", "booksup": return [.books]
        case "album", "albumbook", "albumlb": return [.album]
        case "mem": return [.mem]
        case "arch": return [.arch(day: "2026-09-02", q: nil, no: nil)]
        case "archhits": return [.arch(day: nil, q: "安静", no: nil)]
        default: return []
        }
    }()
    @StateObject private var letters = LettersModel.shared
    @StateObject private var alerts = AlertsModel()
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
                    case .arch(let day, let q, let no): ArchiveScreen(onBack: pop, day: day, query: q, focusNo: no)
                    case .web(let link): WebShellScreen(onLogout: onLogout, onBack: pop, openDrawer: false, deepLink: link)
                    }
                }
                .zIndex(Double(100 + i))
                .background(EdgeSwipe(onBack: pop))
                .transaction { $0.animation = nil }
            }
        }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }

    @State private var kbUp = false
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
                    if farFromBottom && !atBottom { jumpButton(proxy) }
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
        .overlay { if showMeal { MealSheet(shown: $showMeal, onSent: { line in
            mealEchoes.append(MealEcho(line: line, at: Date()))
            mealOk = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { mealOk = false }
        }).zIndex(60).ignoresSafeArea(.keyboard) } }
        .onChange(of: model.loadTick) { _ in
            // 正牌小纸条（服务器物化进正史的 meal ping）到了就把回显撤掉，不重影
            mealEchoes.removeAll { e in
                model.msgs.contains { $0.isPing && $0.meal == true && (TimeFmt.parse($0.ts ?? "") ?? .distantPast) >= e.at.addingTimeInterval(-120) }
            }
        }
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
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in Task { await lintel.refresh() } }
        .onAppear { model.onLogout = onLogout }
        .onReceive(pulseTimer) { _ in Task { await model.pulse() } }
        .onChange(of: phase) { p in
            if p == .active { Task { await model.pulse(); await letters.refresh(); if !letters.unseen.isEmpty, path.isEmpty, !Preview.on { letterAlertOn = true } } }
            if p == .background { model.detach() }
        }
        .onChange(of: picks) { _ in Task { await loadPicks() } }
        .fullScreenCover(isPresented: $showWeb) { WebShellScreen(onLogout: onLogout) }
        .overlay { DrawerView(shown: $drawerOn, unread: 0, onLogout: onLogout, onNavigate: { r in drawerOn = false; path.append(r) }).zIndex(50) }
        .overlay { if model.door?.closed == true { DoorView(model: model).zIndex(120) } }
        .overlay { if let s = alerts.current { StripPop(icon: s.icon, title: s.title, en: s.en, msg: s.msg, onClose: { alerts.dismiss() }).zIndex(60) } }
        .task { await alerts.poll(); await alerts.healthOnce() }
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

    private var listContent: some View {
        LazyVStack(spacing: 22) {
            if model.renderFrom > 0 {
                Button { model.loadOlderDay() } label: {
                    Text("· 更早 ·").font(Theme.round(12)).tracking(1).foregroundColor(Theme.muted)
                }.buttonStyle(.plain).padding(.top, 4)
            }
            ForEach(model.items) { r in row(r.item) }
            if let live = model.live { VStack(alignment: .leading, spacing: 22) { liveView(live) }.id("live") }
            ForEach(mealEchoes) { e in
                PingChipView(msg: Msg(role: "user", content: e.line, ts: nil), forceMeal: true).id("echo-\(e.id)")
            }
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10)   // 网页 #messages padding-bottom 10
        .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id("bottom") }   // 「到底」锚点不占行（占行会多出一格 spacing）
        .background(ScrollObserver(name: "chat") { y, ch, vh in
            let total = max(ch, 1)
            farFromBottom = (total - y - vh) > 40
            atBottom = !farFromBottom
            if Preview.on { dbg = String(format: "y=%.0f ch=%.0f vh=%.0f", y, ch, vh) }
        })
    }

    private func messageList(_ proxy: ScrollViewProxy) -> some View {
        ScrollView { listContent }
            .scrollIndicators(.visible)               // 系统原生指示条（染成赤陶，见 ScrollObserver）：能拖、拉到头会缩、和网页同款
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .topLeading) { if Preview.on { Text(dbg + " n=\(model.items.count)").font(.system(size: 9)).foregroundColor(.red).padding(4) } }
            .background(KeyboardDismisser())
            .onChange(of: model.items.count) { _ in if atBottom { scrollBottom(proxy) } }
            .onChange(of: model.live?.items.count ?? 0) { _ in if atBottom { scrollBottom(proxy) } }
            .onChange(of: model.live?.events ?? 0) { _ in if atBottom { DispatchQueue.main.async { pinBottom() } } }   // 流式：字长出来就跟着到底（寻验：看不见流式）
            .onChange(of: model.sending) { s in if s { scrollBottom(proxy, animated: true) } }
            .onChange(of: model.loadTick) { _ in scrollBottom(proxy) }
            .onChange(of: mealEchoes.count) { n in if n > 0, !farFromBottom { scrollBottom(proxy, animated: true) } }
            .onReceive(NotificationCenter.default.publisher(for: .keepThinkToggled)) { _ in
                // 末条的 thought 展开/折回改了内容高：原本在底就重新钉底，别留一截空（寻验 44）
                guard atBottom, let id = lastId else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .bottom) }
            }
            // 键盘跟随只能走 SwiftUI 自己的 scrollTo（UIKit 改 offset 会被它每帧写回）：原本在底，键盘来/走都钉着最后一行，
            // 时长取键盘的，曲线取系统键盘曲线的近似
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { n in
                guard atBottom, path.isEmpty, !showMeal, !drawerOn, let id = lastId else { return }
                let dur = (n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                withAnimation(.timingCurve(0.38, 0.7, 0.125, 1.0, duration: dur)) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear { Task { await model.load() } }
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


    /// 顶栏（照网页 header）：左上角展开钮（42px 圆、发丝圈、三道 16×2 靠左）| 门楣列 | 吃饭钮。
    private var header: some View {
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
                    if mealOk { Text("✓").font(.system(size: 17, weight: .bold)).foregroundColor(Theme.accent) }
                    else { Image("bowl").renderingMode(.template).resizable().frame(width: 20, height: 20).foregroundColor(Theme.muted) }
                }.frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .background(Theme.bg)
        .zIndex(30)
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
                        Text(e).font(Theme.serif(15)).foregroundColor(.red)
                    } else if s.shown > 0 {
                        RichText(attr: MDWhole.make(s.shownText)).padding(.vertical, 11)
                    }   // 还没吐字：什么都不画（照网页；寻：没有 thinking 就别显示 thought）
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 输入卡（照网页 #inputbox）：composer 底、1.5px 发丝圈、26 圆角、两层阴影；上排文字，下排＋与发送。
    private var composer: some View {
        VStack(spacing: 6) {
            if !pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pending.enumerated()), id: \.offset) { i, u in
                            ZStack(alignment: .topTrailing) {
                                DataImage(src: u, maxW: 64, maxH: 64, radius: 12)
                                Button { pending.remove(at: i) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                        .frame(width: 18, height: 18).background(Color.black.opacity(0.55), in: Circle())
                                }.buttonStyle(.plain).offset(x: 4, y: -4)
                            }
                        }
                    }.padding(.horizontal, 2).padding(.top, 6)   // 给右上角的 × 留出头
                }
            }
            Composer(text: $draft, focused: $composerFocused)      // 字同她的气泡（Lora→宋体）、行距 1.5、光标赤陶 40%
                .padding(.top, 2).padding(.bottom, 4)
            HStack(spacing: 8) {
                PhotosPicker(selection: $picks, maxSelectionCount: 4, matching: .images) {
                    Image("plus").renderingMode(.template).resizable().frame(width: 17, height: 17).foregroundColor(Theme.text)
                        .frame(width: 36, height: 36).background(Theme.attachBg, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, -4)
                Spacer()
                Button {
                    if model.sending { model.stop() } else if canSend { sendNow() }
                } label: {
                    Group {
                        if model.sending {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.text).frame(width: 12, height: 12)
                        } else if canSend {
                            Text("↑").font(.system(size: 17, weight: .medium)).foregroundColor(.white)   // 照网页 #send .arr
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
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.hairRing, lineWidth: 1.5))
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .shadow(color: Color.black.opacity(0.09), radius: 19, y: 14)
        .padding(.horizontal, 10).padding(.top, 0).padding(.bottom, 8)   // 消息区到输入卡＝网页 #messages padding-bottom 10，别再叠
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty }

    private func sendNow() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = pending
        draft = ""; pending = []
        composerFocused = false
        model.send(text: t, images: imgs)
    }

    /// 列表末尾的那一行（懒列表的「到底」锚点按估算高度定位，最后一行没排出来就停在它上头——寻验：最后一条克的话总看不见）
    private var lastId: String? {
        if let e = mealEchoes.last { return "echo-\(e.id)" }
        if model.live != nil { return "live" }
        return model.items.last?.id
    }
    /// 到底：先让 SwiftUI 滚到最后一行本身（把它真排出来），再由 UIKit 按真实内容高精确钉底（含底部 10 留白）。
    /// 补钉只在真的没到底时才动（寻验：开屏后界面上下弹几下＝反复重滚）。
    private func scrollBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        let go = {
            if let id = lastId { proxy.scrollTo(id, anchor: .bottom) } else { proxy.scrollTo("bottom", anchor: .bottom) }
        }
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
    var onBack: () -> Void = {}
    var openDrawer = true
    var deepLink = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onBack(); dismiss() } label: {
                    Text("‹").font(.system(size: 26)).foregroundColor(Theme.muted).frame(width: 34, height: 34)
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
