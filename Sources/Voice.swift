import SwiftUI
import AVFoundation

/// 语音条（09-14 寻定，夜里二版）：长按输入行录，**边说边出字**——字由腾讯实时识别给（手机直连腾讯，网关只签票），
/// 浮在输入卡上方的小卡里长；上滑取消；松手后字落进输入框，可改可直接发。发出去时带音频＋定稿＋识别原文，
/// 网关让 Gemini 照定稿标记号、写语气（她不等，克那边多想几秒）。气泡：小气泡「8″ 声纹」＋正文另起一个气泡，语气灰字在时间前。
struct Voice: Codable, Equatable {
    var url: String            // /uploads/voice/<hash>.m4a（空＝还没传上去）
    var dur: Double
    var tone: String? = nil
    var text: String? = nil    // 转写（带记号）；正史 content 是「［语音条］正文（秒·语气）」，气泡只画正文
    var orig: String? = nil    // 识别原文（她改字前），学编辑用；只上行不下行
    var annotate: Bool? = nil  // 二版：让网关照定稿标记号
    var pending: Bool? = nil   // 本地回显：还在传
    var failed: String? = nil  // 本地回显：失败原因
    var secs: String { dur < 1 ? "1″" : "\(Int(dur.rounded()))″" }
}

// MARK: - 录音 + 实时识别

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    static let shared = VoiceRecorder()
    @Published var recording = false
    @Published var level: CGFloat = 0        // 0…1，画音量
    @Published var seconds = 0.0
    @Published var cancelHint = false        // 手指上滑到取消区
    @Published var editHint = false          // 手指右滑到编辑区（松手字进输入框、键盘升起）
    @Published var liveText = ""             // 边说边出的字（已定句 + 当前半句）
    @Published var asrState = ""             // 空＝正常；「识别没连上」之类给界面提示
    static let maxSeconds = 120.0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter? = nil
    private var file: AVAudioFile? = nil
    private var fileURL: URL? = nil
    private var ws: URLSessionWebSocketTask? = nil
    private var wsOpen = false
    private var pendingFrames: [Data] = []   // 票还没签好时先攒着
    private var carry = Data()               // 不足 40ms 的尾巴
    private var finished: [String] = []
    private var partial = ""
    private var gotFinal = false
    private var finalWaiter: CheckedContinuation<Void, Never>? = nil
    private var t0 = Date()
    private var ticker: Timer? = nil
    private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    func requestPermission() async -> Bool {
        if #available(iOS 17, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
    }

    /// 起录：麦克风当场开（票还没到的那几百毫秒音频先攒着），同时去网关签票、连腾讯
    func start() -> Bool {
        guard !recording else { return true }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
        } catch { PushRegistrar.diag("voice: session \(error.localizedDescription)"); return false }
        VoicePlayer.shared.stop()
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, let conv = AVAudioConverter(from: inFmt, to: Self.pcmFormat) else { PushRegistrar.diag("voice: no converter"); return false }
        converter = conv
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).m4a")
        do {
            file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000],
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        } catch { PushRegistrar.diag("voice: file \(error.localizedDescription)"); return false }
        fileURL = url
        finished = []; partial = ""; liveText = ""; asrState = ""; gotFinal = false; pendingFrames = []; carry = Data(); wsOpen = false
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buf, _ in
            guard let self else { return }
            // 音量（原始浮点缓冲的 RMS）
            var rms: Float = 0
            if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
                rms = sqrt(sum / Float(buf.frameLength))
            }
            // 转 16k Int16 单声道：写文件 + 切 40ms 帧推腾讯
            let ratio = Self.pcmFormat.sampleRate / buf.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64) else { return }
            var consumed = false
            var err: NSError? = nil
            conv.convert(to: out, error: &err) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buf
            }
            guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
            let data = Data(bytes: p, count: Int(out.frameLength) * 2)
            Task { @MainActor in
                self.level = self.level * 0.6 + CGFloat(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 50))) * 0.4
                try? self.file?.write(from: out)
                self.push(data)
            }
        }
        do { engine.prepare(); try engine.start() } catch { PushRegistrar.diag("voice: engine \(error.localizedDescription)"); input.removeTap(onBus: 0); return false }
        t0 = Date(); seconds = 0; level = 0; cancelHint = false; editHint = false; recording = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.seconds = Date().timeIntervalSince(self.t0)
                if self.seconds >= Self.maxSeconds { _ = await self.finish() }
            }
        }
        RunLoop.main.add(ticker!, forMode: .common)
        Task { await connect() }
        return true
    }

    /// 40ms 一帧（1280 字节）推给腾讯；票没到先攒
    private func push(_ d: Data) {
        carry.append(d)
        while carry.count >= 1280 {
            let frame = carry.prefix(1280); carry.removeFirst(1280)
            if wsOpen, let ws { ws.send(.data(Data(frame))) { _ in } } else { pendingFrames.append(Data(frame)) }
        }
    }

    private func connect() async {
        do {
            let url = try await GatewayAPI.voiceTicket()
            let task = URLSession.shared.webSocketTask(with: url)
            ws = task
            task.resume()
            receiveLoop(task)
        } catch {
            PushRegistrar.diag("voice: ticket \(error.localizedDescription)")
            asrState = "识别没连上"
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] res in
            Task { @MainActor in
                guard let self, self.ws === task else { return }
                switch res {
                case .failure(let e):
                    if self.recording && !self.gotFinal { PushRegistrar.diag("voice: ws \(e.localizedDescription)"); self.asrState = "识别断了" }
                    self.finalWaiter?.resume(); self.finalWaiter = nil
                    return
                case .success(let m):
                    var txt = ""
                    if case .string(let s) = m { txt = s } else if case .data(let d) = m { txt = String(decoding: d, as: UTF8.self) }
                    if let d = txt.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        let code = j["code"] as? Int ?? 0
                        if code != 0 {
                            PushRegistrar.diag("voice: asr code=\(code) \((j["message"] as? String ?? "").prefix(60))")
                            self.asrState = "识别出错 \(code)"
                        } else if let r = j["result"] as? [String: Any] {
                            let s = (r["voice_text_str"] as? String) ?? ""
                            if (r["slice_type"] as? Int) == 2 { self.finished.append(s); self.partial = "" } else { self.partial = s }
                            self.liveText = self.finished.joined() + self.partial
                        } else if !self.wsOpen {
                            // 第一条「success」：通道通了，把攒着的帧倒出去
                            self.wsOpen = true
                            for f in self.pendingFrames { task.send(.data(f)) { _ in } }
                            self.pendingFrames = []
                        }
                        if (j["final"] as? Int) == 1 { self.gotFinal = true; self.finalWaiter?.resume(); self.finalWaiter = nil; return }
                    }
                    self.receiveLoop(task)
                }
            }
        }
    }

    /// 松手：停麦、收文件、给腾讯发 end、等最后一句（最多 2.5 秒）。返回 (文件, 秒数, 字)；不到 1 秒当没录。
    func finish() async -> (URL, Double, String)? {
        guard recording else { return nil }
        let dur = Date().timeIntervalSince(t0)
        stopCapture()
        if dur < 1 { discardFile(); closeWS(); recording = false; return nil }
        if wsOpen, let ws {
            ws.send(.string(#"{"type":"end"}"#)) { _ in }
            if !gotFinal {
                await withTaskGroup(of: Void.self) { g in
                    g.addTask { await withCheckedContinuation { c in Task { @MainActor in self.finalWaiter = c } } }
                    g.addTask { try? await Task.sleep(nanoseconds: 2_500_000_000) }
                    await g.next(); g.cancelAll()
                }
            }
        }
        closeWS()
        recording = false
        let text = (finished.joined() + partial).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = fileURL else { return nil }
        return (url, dur, text)
    }

    func cancel() {
        guard recording else { return }
        stopCapture(); discardFile(); closeWS(); recording = false; cancelHint = false; editHint = false; liveText = ""
    }

    private func stopCapture() {
        ticker?.invalidate(); ticker = nil
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        file = nil   // 关文件（AVAudioFile 析构时收尾）
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func discardFile() { if let u = fileURL { try? FileManager.default.removeItem(at: u) }; fileURL = nil }
    private func closeWS() { ws?.cancel(with: .normalClosure, reason: nil); ws = nil; wsOpen = false; pendingFrames = [] }
}

// MARK: - 回放

@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()
    @Published var playing: String? = nil     // 正在放的 url
    @Published var progress: Double = 0
    private var player: AVAudioPlayer? = nil
    private var tick: Timer? = nil
    private var loading: String? = nil

    func toggle(_ url: String) {
        if playing == url { stop(); return }
        stop()
        loading = url
        Task {
            guard let data = await Self.fetch(url), loading == url else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                let p = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.m4a.rawValue)
                p.delegate = self
                player = p; playing = url; progress = 0
                p.play()
                tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let p = self.player else { return }
                        self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
                    }
                }
                RunLoop.main.add(tick!, forMode: .common)
            } catch { PushRegistrar.diag("voice: play \(error.localizedDescription)") }
        }
    }

    func stop() {
        loading = nil
        player?.stop(); player = nil; tick?.invalidate(); tick = nil
        playing = nil; progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }

    /// 音频走 DiskCache 落盘（同一条只下一次）
    private static func fetch(_ url: String) async -> Data? {
        let key = "voice-" + (url.split(separator: "/").last.map(String.init) ?? url)
        if let d = DiskCache.read(key) { return d }
        guard let u = URL(string: url, relativeTo: Gateway.home) else { return nil }
        var r = URLRequest(url: u)
        if let t = Keychain.token { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        DiskCache.write(key, d)
        return d
    }
}

// MARK: - 气泡

/// 她的语音气泡（寻 09-14 定，照微信「抄美了」）：先一个小气泡「8″ 声纹」，正文另起一个气泡（和打字的一模一样）；
/// 语气那句放在时间那行前面（UserRowView 画），不带「语气：」。点小气泡放，放的时候三道弧一道道亮。
/// 传送中：小气泡里是转圈，正文照常；失败：正文位置灰字写原因。
struct VoiceBubble: View {
    let voice: Voice
    let text: String
    var highlight = ""
    @ObservedObject private var player = VoicePlayer.shared
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { if !voice.url.isEmpty, voice.pending != true { player.toggle(voice.url) } } label: {
                HStack(spacing: 10) {
                    if voice.pending == true {
                        ProgressView().controlSize(.small).tint(Theme.muted).frame(width: 22, height: 20)
                    } else {
                        Text(voice.secs).font(Theme.mono(13, weight: .medium)).foregroundColor(Theme.text)
                    }
                    WavesIcon(playing: player.playing == voice.url)
                }
                .padding(EdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 14))
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(.plain)
            if let f = voice.failed {
                Text(f).font(Theme.round(13.5)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else if !text.isEmpty {
                let attr = Voice.tintCues(MD.xunNS(text))
                RichText(attr: highlight.isEmpty ? attr : ArchiveScreen.highlight(attr, highlight))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .textSelection(.enabled)
            }
        }
    }
}

/// 声纹：右边一个小点、左边三道弧（镜像的，声音朝正文那边发——寻 09-14：照微信、要镜像）。
/// 放的时候按 0.35 秒一拍从内到外一道道亮成赤陶，循环；不放时三道都是深字色。
/// 09-15 寻：弧太张、上下顶着气泡——弧从 90° 收到 60°（150°→210°），整个图标高 15、宽 17。
struct WavesIcon: View {
    var playing: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
            let lit = playing ? Int(ctx.date.timeIntervalSinceReferenceDate / 0.35) % 3 + 1 : 3
            Canvas { g, size in
                let c = CGPoint(x: size.width - 2.5, y: size.height / 2)
                var dot = Path(); dot.addEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
                g.fill(dot, with: .color(playing ? Theme.accent : Theme.text))
                for (i, r) in [5.0, 9.0, 13.0].enumerated() {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(150), endAngle: .degrees(210), clockwise: false)
                    let on = i < lit
                    g.stroke(p, with: .color(playing ? (on ? Theme.accent : Theme.muted.opacity(0.35)) : Theme.text), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
            }
            .frame(width: 17, height: 15)
        }
    }
}

/// 录音中替换输入行的那条：跳动的音量条＋秒数＋「松手…」；上滑到位时提示变赤陶
struct RecordingBar: View {
    @ObservedObject var rec: VoiceRecorder
    var body: some View {
        HStack(spacing: 10) {
            // 09-15 寻：条太粗——2 点宽、间距 2.5、最高 14
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<16, id: \.self) { i in
                    let h = 3 + 11 * rec.level * CGFloat([0.5, 0.8, 1, 0.7, 0.9, 0.6, 1, 0.8, 0.5, 0.9, 0.7, 1, 0.6, 0.8, 0.5, 0.9][i])
                    Capsule().fill(rec.cancelHint ? Theme.accent : Theme.text.opacity(rec.editHint ? 0.35 : 0.7)).frame(width: 2, height: max(3, h))
                        .animation(.linear(duration: 0.08), value: rec.level)
                }
            }
            .frame(height: 22)
            Text(String(format: "%d″", Int(rec.seconds))).font(Theme.mono(13, weight: .medium)).foregroundColor(Theme.text)
            Spacer()
            // 提示：默认「松手发出」；上滑「松手取消」（赤陶）；右滑「松手编辑」（深字）——寻 09-14 夜定：不用改就直接发，要改才滑
            Text(rec.cancelHint ? "松手取消" : rec.editHint ? "松手编辑" : (rec.asrState.isEmpty ? "松手发出" : rec.asrState))
                .font(Theme.round(12.5)).foregroundColor(rec.cancelHint ? Theme.accent : Theme.muted)
        }
        .frame(height: Composer.minH)
    }
}

/// 边说边出字的小卡（寻 09-14 定的 A：只放字，干净）：白卡、她的字体、末尾一根赤陶光标；字还没来时一行灰字
struct LiveCard: View {
    @ObservedObject var rec: VoiceRecorder
    var body: some View {
        HStack(spacing: 0) {
            if rec.liveText.isEmpty {
                Text(rec.asrState.isEmpty ? "说吧…" : rec.asrState).font(Theme.round(15)).foregroundColor(Theme.muted)
            } else {
                // 字同她的气泡；光标是接在最后一个字后面的一个细竖条（09-15 寻：光标要跟字，不是排在行末）
                (Text(rec.liveText).font(Font(Theme.uiUser(17))).foregroundColor(Theme.text)
                 + Text("▏").font(Font(Theme.uiUser(17))).foregroundColor(Theme.accent))
                    .lineSpacing(4)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.composer)
            .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
            .shadow(color: Color.black.opacity(0.09), radius: 19, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.hairRing, lineWidth: 1.5))
        .padding(.horizontal, 26)
    }
}

/// A 版的两侧提示（寻 09-15 定回 A）：卡下方「← 取消」「编辑 →」，选中换淡陶土底＋赤陶字
struct HoldHints: View {
    @ObservedObject var rec: VoiceRecorder
    var body: some View {
        HStack {
            pill("← 取消", on: rec.cancelHint)
            Spacer()
            pill("编辑 →", on: rec.editHint)
        }
        .padding(.horizontal, 22)
    }
    private func pill(_ t: String, on: Bool) -> some View {
        Text(t).font(Theme.round(13)).foregroundColor(on ? Theme.accent : Theme.muted)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? Theme.dyn(0xEFE4DC, 0x3A302B) : Color.clear, in: Capsule())
    }
}

extension Voice {
    /// 转写里 Gemini 标的记号「——（拖长，撒娇）」「（笑）」（克 09-14 要的）：在她的气泡里染成灰字，和正文分开
    static func tintCues(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        guard let re = try? NSRegularExpression(pattern: #"——|（[^（）]{1,8}）"#) else { return a }
        for r in re.matches(in: m.string, range: NSRange(location: 0, length: m.length)) {
            m.addAttribute(.foregroundColor, value: Theme.uiMuted, range: r.range)
        }
        return m
    }
    /// 正史 content＝「［语音条］正文（时长·语气：…）」（寻 09-14 定的格式；旧的「正文\n（语音条 · …）」也认），画气泡时只留正文
    static func stripNote(_ s: String) -> String {
        var t = s
        if t.hasPrefix("［语音条］") { t = String(t.dropFirst(5)) }
        if let r = t.range(of: #"（\d+秒[^）]*）\s*$"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: #"\n?（语音条 · [^）]*）\s*$"#, options: .regularExpression) { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
