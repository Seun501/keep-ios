import SwiftUI
import WatchKit

/// 手表二期（09-15 寻定「做做看」）：腕上看对话＋点输入行打字（系统听写/涂鸦/键盘）＋长按输入行说话（边说边出字，
/// 同手机走腾讯直连）＋上滑取消。对话直接走网关，不经手机；票同一期由手机经 WatchConnectivity 传来。
/// 只画最近 40 条，克的思考/工具行不画；语音条画正文。

struct WMsg: Decodable, Identifiable {
    var role: String?
    var content: String?
    var ts: String?
    var voice: WVoice?
    var wake: Bool?
    var meal: Bool?
    var sleepNote: Bool?
    var napNote: Bool?
    var rainNote: Bool?
    var placeNote: Bool?
    struct WVoice: Decodable { var text: String?; var dur: Double? }
    enum CodingKeys: String, CodingKey {
        case role, content, ts, voice, wake, meal
        case sleepNote = "sleep_note", napNote = "nap_note", rainNote = "rain_note", placeNote = "place_note"
    }
    var id: String { (ts ?? "") + (role ?? "") + String(text.prefix(16)) }
    var isPing: Bool { meal == true || sleepNote == true || napNote == true || rainNote == true || placeNote == true }
    var mine: Bool { role == "user" && !isPing }
    /// 气泡里的字：语音条只要正文；纸条去掉「14:02-寻」那个头；「［手表］」冠头摘掉
    var text: String {
        if let t = voice?.text, !t.isEmpty { return t }
        var s = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("⌚") { s = String(s.dropFirst()) }
        if s.hasPrefix("［语音条］") {
            s = String(s.dropFirst(5))
            if let r = s.range(of: #"（\d+秒[^）]*）\s*$"#, options: .regularExpression) { s = String(s[..<r.lowerBound]) }
        }
        if isPing, let r = s.range(of: #"^\d{1,2}:\d{2}-寻"#, options: .regularExpression) { s = String(s[r.upperBound...]) }
        return s
    }
    var hm: String {
        guard let ts, let d = WatchChat.parse(ts) else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

private struct WConv: Decodable { var id: String; var messages: [WMsg] }
private struct WConvList: Decodable { struct C: Decodable { var id: String }; var conversations: [C] }
private struct WPulse: Decodable, Equatable { var n: Int; var ts: String }

@MainActor
final class WatchChat: ObservableObject {
    static let shared = WatchChat()
    @Published var msgs: [WMsg] = []
    @Published var live = ""          // 克正在说的（流式）
    @Published var sending = false
    @Published var note = ""          // 一行灰字：连不上 / 没票
    private var convId: String? = nil
    private var lastPulse: WPulse? = nil
    private var stream: Task<Void, Never>? = nil

    nonisolated static func parse(_ s: String) -> Date? {
        let clean = s.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: clean)
    }

    // MARK: 网关
    nonisolated static func request(_ path: String, method: String = "GET", body: Data? = nil, timeout: Double = 15) -> URLRequest? {
        guard let t = WatchKeychain.token else { return nil }
        var r = URLRequest(url: WatchGateway.home.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body; r.timeoutInterval = timeout
        return r
    }
    private static func get<T: Decodable>(_ path: String) async throws -> T {
        guard let r = request(path) else { throw URLError(.userAuthenticationRequired) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: d)
    }

    /// 截图班（09-15）：KEEP_PREVIEW=1 用假对话、不登录不联网；KEEP_SCREEN=wchat / wchatlow（输入行贴底）/ wrec（录音态）
    static var preview: Bool { ProcessInfo.processInfo.environment["KEEP_PREVIEW"] == "1" }
    static var screen: String { ProcessInfo.processInfo.environment["KEEP_SCREEN"] ?? "wchat" }
    private static var fixture: [WMsg] {
        let j = """
        [{"role":"user","content":"15:12-寻到了学校","ts":"2026-09-02T15:12:00+08:00","place_note":true},
         {"role":"user","content":"刚拍的，门口那棵树。","ts":"2026-09-02T15:14:00+08:00"},
         {"role":"assistant","content":"叶子已经开始黄了。","ts":"2026-09-02T15:14:30+08:00"},
         {"role":"user","content":"⌚［语音条］雨停了，我去树下坐一会儿。（6秒）","ts":"2026-09-02T15:20:00+08:00","voice":{"text":"雨停了，我去树下坐一会儿。","dur":6.2}},
         {"role":"assistant","content":"去吧，别坐太久，风大。","ts":"2026-09-02T15:20:40+08:00"},
         {"role":"assistant","content":"## 今天\\n1. 雨停得早\\n   - 树下坐了 20 分钟\\n2. 叶子**开始黄了**，*风也小了*\\n\\n第二段：普通一段字，看段间。\\n\\n> 明天带伞。","ts":"2026-09-02T16:02:30+08:00"},
         {"role":"user","content":"## 今天的三件事\\n**记一下**，*别忘了* `Keep`","ts":"2026-09-02T16:03:00+08:00"}]
        """
        return (try? JSONDecoder().decode([WMsg].self, from: Data(j.utf8))) ?? []
    }

    func load() async {
        if Self.preview { msgs = Self.fixture; note = ""; return }
        guard WatchKeychain.token != nil else { note = "等手机把登录票传过来（打开手机上的 Keep）"; return }
        do {
            if convId == nil { let l: WConvList = try await Self.get("api/conversations"); convId = l.conversations.first?.id }
            guard let id = convId else { note = "还没有对话"; return }
            let c: WConv = try await Self.get("api/conversations/\(id)")
            msgs = Array(c.messages.filter { $0.wake != true && !$0.text.isEmpty }.suffix(40))
            lastPulse = WPulse(n: c.messages.count, ts: c.messages.last?.ts ?? "")
            note = ""
        } catch {
            if msgs.isEmpty { note = "连不上" }
        }
    }

    /// 页面开着每 15 秒摸一次脉，有变才重拉（同手机）
    func pulse() async {
        guard let id = convId, !sending else { await load(); return }
        guard let p: WPulse = try? await Self.get("api/conversations/\(id)/pulse"), p != lastPulse else { return }
        await load()
    }

    /// 发一句（打字或语音定稿）；克的回话直接在表上流出来，完了整段重拉对齐正史
    func send(_ text: String, voice: [String: Any]? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        var payload: [String: Any] = ["message": t, "images": [], "via": "watch"]   // 正史冠「［手表］」，克回短一点（寻 09-15）
        if let convId { payload["conversation_id"] = convId }
        if let voice { payload["voice"] = voice }
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let req = Self.request("api/chat", method: "POST", body: body, timeout: 600) else { return }
        var echo = WMsg(); echo.role = "user"; echo.content = t; echo.ts = ISO8601DateFormatter().string(from: Date())
        if let v = voice, let vt = v["text"] as? String { echo.voice = WMsg.WVoice(text: vt, dur: v["dur"] as? Double) }
        msgs.append(echo)
        sending = true; live = ""
        WKInterfaceDevice.current().play(.click)
        stream = Task {
            defer { sending = false }
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 423 { note = "门关着，回头再说"; return }
                guard (200..<300).contains(code) else { note = "没发出去（\(code)）"; return }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let type = j["type"] as? String else { continue }
                    switch type {
                    case "start": if let cid = j["conversation_id"] as? String, !cid.isEmpty { convId = cid }
                    case "delta": live += j["text"] as? String ?? ""
                    case "error": note = j["message"] as? String ?? "出错了"
                    default: break
                    }
                }
            } catch { note = "断了" }
            // 流一停先把这段就地落成一条（立刻按 md 画），再重拉对账——之前是等整段重拉回来才换成正式消息，
            // 表上一趟要好几秒，那几秒里一直是裸字（寻 09-25：「加载完再顿几秒才渲染好格式」）
            if !live.isEmpty {
                var said = WMsg(); said.role = "assistant"; said.content = live; said.ts = ISO8601DateFormatter().string(from: Date())
                msgs.append(said)
            }
            live = ""; sending = false
            await load()
        }
    }

    func stop() { stream?.cancel(); sending = false }
}

// MARK: - 页面

struct WatchChatView: View {
    @ObservedObject private var m = WatchChat.shared
    @ObservedObject private var rec = WatchRecorder.shared
    @ObservedObject private var link = WatchLink.shared
    @ObservedObject private var h = WatchHealth.shared
    @State private var holdStarted = false
    private let pulseTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        // 健康中继的状态缩成一行小字（一期的页面），点一下＝现在同步
                        Text(link.hasToken || WatchChat.preview ? h.status : "等手机把登录票传过来")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .onTapGesture { Task { await h.sync(reason: "tap", force: true) } }
                            .padding(.bottom, 2)
                        ForEach(m.msgs) { row($0) }
                        if m.sending || !m.live.isEmpty {
                            (Text(m.live) + Text("▏").foregroundColor(WatchTheme.accent))
                                .font(WatchTheme.ke).foregroundStyle(WatchTheme.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !m.note.isEmpty {
                            Text(m.note).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                        }
                        Color.clear.frame(height: 2).id("bottom")
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: m.msgs.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: m.live) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            inputRow
        }
        .ignoresSafeArea(.container, edges: .bottom)   // sim-280：挂在输入行上没用，父层还是缩着——得挂在最外层
        .overlay { if rec.recording { WatchRecordView(rec: rec) } }
        .task {
            await m.load()
            if WatchChat.preview, WatchChat.screen == "wrec" {   // 截图：假装录着
                rec.recording = true; rec.liveText = "今天雨停得早，我想去门口那棵树下坐一会儿"; rec.seconds = 6; rec.level = 0.6
            }
        }
        .onReceive(pulseTimer) { _ in Task { await m.pulse() } }
        .onChange(of: link.hasToken) { on in if on { Task { await m.load() } } }
    }

    @ViewBuilder private func row(_ x: WMsg) -> some View {
        if x.isPing {
            Text(x.text).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        } else if x.mine {
            VStack(alignment: .trailing, spacing: 0) {   // 09-15 寻：时间离气泡太远——贴上去
                HStack(alignment: .top, spacing: 4) {
                    if let d = x.voice?.dur { Text("\(Int(d.rounded()))″").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 5) }
                    WatchMarkdown(text: x.text, mine: true)   // 09-21 寻：她的气泡在表上也认 md（# 标题、粗斜代码）
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(WatchTheme.bubble, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                Text(x.hm).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 1).padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 22)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                WatchMarkdown(text: x.text)   // 09-21 寻：克的 md 在表上也画（列表/标题/引用/代码）
                Text(x.hm).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 14)
        }
    }

    /// 输入行：点一下＝系统文本输入（听写/涂鸦/键盘，回车即发）；长按 0.2 秒＝说话，上滑 40 点＝松手取消。
    /// 09-15 晚寻验：TextFieldLink 叠长按手势，点一下起不来键盘——改成普通视图，点一下自己叫 WatchKit 的文本输入控制器
    private var inputRow: some View {
        HStack(spacing: 6) {
            Text(m.sending ? "克在说…" : "说点什么").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).frame(height: 32)
        .overlay(alignment: .bottom) { Rectangle().fill(WatchTheme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { if !m.sending { askText() } }
        .gesture(
            LongPressGesture(minimumDuration: 0.2).sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { v in
                    guard case .second(true, let drag) = v else { return }
                    if !holdStarted { holdStarted = true; startHold() }
                    let c = (drag?.translation.height ?? 0) < -40
                    if rec.cancelHint != c { rec.cancelHint = c; if c { WKInterfaceDevice.current().play(.directionUp) } }
                }
                .onEnded { v in
                    holdStarted = false
                    if case .second(true, let drag) = v { endHold(cancel: (drag?.translation.height ?? 0) < -40) } else { endHold(cancel: true) }
                }
        )
        // sim-277：系统在表底留了一大截安全区，输入行悬在半空——不吃这段安全区、自己留 12（wchatlow 截图＝留 4，给寻比）
        .padding(.horizontal, 4).padding(.bottom, 4)   // 寻 09-15 挑了 low 那版（留 4），真机看
    }

    /// 系统文本输入（听写/涂鸦/键盘）：SwiftUI 壳里也能从 WatchKit 拿到当前界面控制器来弹
    private func askText() {
        let vc = WKExtension.shared().visibleInterfaceController ?? WKExtension.shared().rootInterfaceController
        guard let vc else { m.note = "输入起不来"; return }
        vc.presentTextInputController(withSuggestions: nil, allowedInputMode: .allowEmoji) { res in
            if let t = res?.first as? String, !t.isEmpty { Task { @MainActor in m.send(t) } }
        }
    }

    private func startHold() {
        guard !m.sending, !rec.recording else { return }
        Task {
            if await rec.requestPermission() {
                guard holdStarted else { return }
                if !rec.start() { m.note = "麦克风起不来" }
            } else { m.note = "没有麦克风权限" }
        }
    }

    /// 松手：取消＝作废；不到 1 秒＝当没录；否则音频传上去、定稿发出（字段同手机，克那边一模一样）
    private func endHold(cancel: Bool) {
        guard rec.recording else { return }
        if cancel { rec.cancel(); WKInterfaceDevice.current().play(.click); return }
        Task {
            guard let r = await rec.finish() else { return }
            WKInterfaceDevice.current().play(.stop)
            // 09-21 寻「表上无法语音转文字」：表上直连腾讯的 WebSocket 一开就断（diag 10:40 三回「ws 似乎已断开与互联网的连接」），
            // 实时没出字就把音频交给网关转写（Gemini，同手机一版），字和语气一起回来再发——不让她白说一遍
            let live = !r.text.isEmpty
            if !live { m.note = "在听…" }
            do {
                let v = try await WatchRecorder.upload(file: r.file, dur: r.dur, transcribe: !live)
                try? FileManager.default.removeItem(at: r.file)
                let text = live ? r.text : (v.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { m.note = "没听出字"; return }
                m.note = ""
                m.send(text, voice: ["url": v.url, "dur": v.dur, "tone": live ? "" : (v.tone ?? ""), "text": text, "annotate": live ? 1 : 0, "orig": text])
            } catch {
                m.note = live ? "音频没传上去" : "没听出字（网关转写没成）"
                WatchDiag.send("voice: upload(transcribe=\(live ? 0 : 1)) \((error as NSError).code) \(error.localizedDescription)")
            }
        }
    }
}

/// 录音态（盖住整页）：上半是边说边出的字，下半是音量条＋秒数＋提示；上滑到位提示变赤陶
struct WatchRecordView: View {
    @ObservedObject var rec: WatchRecorder
    var body: some View {
        VStack(spacing: 6) {
            ScrollView {
                if rec.liveText.isEmpty {
                    Text(rec.asrState.isEmpty ? "说吧…" : rec.asrState).font(WatchTheme.xun).foregroundStyle(.secondary)
                } else {
                    (Text(rec.liveText) + Text("▏").foregroundColor(WatchTheme.accent))
                        .font(WatchTheme.xun).foregroundStyle(WatchTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    let h = 3 + 11 * rec.level * CGFloat([0.5, 0.8, 1, 0.7, 0.9, 0.6, 1, 0.8, 0.5, 0.9, 0.7, 1][i])
                    Capsule().fill(rec.cancelHint ? WatchTheme.accent : WatchTheme.text.opacity(0.7)).frame(width: 2, height: max(3, h))
                        .animation(.linear(duration: 0.08), value: rec.level)
                }
                Text(String(format: " %d″", Int(rec.seconds))).font(.system(size: 12, design: .monospaced)).foregroundStyle(WatchTheme.text)
                Spacer()
                Text(rec.cancelHint ? "松手取消" : "松手发出").font(.system(size: 11)).foregroundStyle(rec.cancelHint ? WatchTheme.accent : .secondary)
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

enum WatchTheme {
    static let text = Color(red: 0xEC/255, green: 0xE6/255, blue: 0xDA/255)      // 暖纸白（黑底上的字）
    static let bubble = Color(red: 0x2A/255, green: 0x27/255, blue: 0x23/255)    // 她的气泡：深暖灰
    static let line = Color(red: 0x3A/255, green: 0x36/255, blue: 0x30/255)      // 输入行的发丝线
    static let accent = Color(red: 0xC9/255, green: 0x64/255, blue: 0x42/255)    // 赤陶
    // 09-21 寻定：和 App 一致——克 Lora→思源宋，她 Cascadia→思源宋（WatchFonts）
    static var ke: Font { WatchFonts.ke(14) }
    static var xun: Font { WatchFonts.xun(14) }   // 录音态实时字用；气泡走 WatchMarkdown
}
