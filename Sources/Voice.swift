import SwiftUI
import AVFoundation

/// 语音条（09-14 寻定：按住说话、松手发出、上滑取消；录完直接发，不先看字；克看到转写的字＋一行小注「语音条 · 秒 · 语气」）。
/// 手机录 AAC/m4a（16k 单声道 32kbps，30 秒约 120K），传网关 `POST /api/voice`，网关叫 Gemini 转写＋写语气，
/// 回来后照普通消息走 `/api/chat`（带 voice 元信息）。气泡上有播放钮和秒数，字在下面。
struct Voice: Codable, Equatable {
    var url: String            // /uploads/voice/<hash>.m4a（空＝还在转写）
    var dur: Double
    var tone: String? = nil
    var text: String? = nil    // 转写的字（正史 content 是「字＋小注」，气泡只画字）
    var pending: Bool? = nil   // 本地回显：录完还没转出来
    var failed: String? = nil  // 本地回显：转写失败的原因
    var secs: String { dur < 1 ? "1″" : "\(Int(dur.rounded()))″" }
}

// MARK: - 录音

@MainActor
final class VoiceRecorder: ObservableObject {
    static let shared = VoiceRecorder()
    @Published var recording = false
    @Published var level: CGFloat = 0        // 0…1，画音量
    @Published var seconds = 0.0
    @Published var cancelHint = false        // 手指上滑到取消区
    private var rec: AVAudioRecorder? = nil
    private var meter: Timer? = nil
    private var t0 = Date()
    static let maxSeconds = 120.0

    func requestPermission() async -> Bool {
        if #available(iOS 17, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
    }

    /// 起录：失败（没权限/会话起不来）返回 false
    func start() -> Bool {
        guard !recording else { return true }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try s.setActive(true)
        } catch { PushRegistrar.diag("voice: session \(error.localizedDescription)"); return false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVEncoderBitRateKey: 32000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else { return false }
            rec = r
        } catch { PushRegistrar.diag("voice: recorder \(error.localizedDescription)"); return false }
        t0 = Date(); seconds = 0; level = 0; cancelHint = false; recording = true
        VoicePlayer.shared.stop()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.rec else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)                       // -160…0
                let lin = CGFloat(max(0, min(1, (db + 50) / 50)))
                self.level = self.level * 0.6 + lin * 0.4
                self.seconds = Date().timeIntervalSince(self.t0)
                if self.seconds >= Self.maxSeconds { _ = self.finish() }
            }
        }
        RunLoop.main.add(meter!, forMode: .common)
        return true
    }

    /// 松手：返回文件和时长；太短（<1 秒）返回 nil（当没录）
    func finish() -> (URL, Double)? {
        guard recording, let r = rec else { return nil }
        let dur = Date().timeIntervalSince(t0)
        r.stop(); rec = nil; meter?.invalidate(); meter = nil; recording = false; level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if dur < 1 { try? FileManager.default.removeItem(at: r.url); return nil }
        return (r.url, dur)
    }

    func cancel() {
        guard recording, let r = rec else { return }
        r.stop(); r.deleteRecording(); rec = nil; meter?.invalidate(); meter = nil; recording = false; level = 0; cancelHint = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
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

    /// 音频走 DiskCache 落盘（同一条只下一次）；路径带口令头（uploads 不要口令，但带着无害）
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
/// 转写中：小气泡里是转圈，正文位置「转写中…」；失败：正文位置灰字写原因。
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
            if voice.pending == true {
                Text("转写中…").font(Theme.round(13.5)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            } else if let f = voice.failed {
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
                    p.addArc(center: c, radius: r, startAngle: .degrees(135), endAngle: .degrees(225), clockwise: false)
                    let on = i < lit
                    g.stroke(p, with: .color(playing ? (on ? Theme.accent : Theme.muted.opacity(0.35)) : Theme.text), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
            }
            .frame(width: 18, height: 18)
        }
    }
}

/// 录音中替换输入行的那条：跳动的音量条＋秒数＋「上滑取消」；上滑到位时整条变赤陶
struct RecordingBar: View {
    @ObservedObject var rec: VoiceRecorder
    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<14, id: \.self) { i in
                    let h = 4 + 16 * rec.level * CGFloat([0.5, 0.8, 1, 0.7, 0.9, 0.6, 1, 0.8, 0.5, 0.9, 0.7, 1, 0.6, 0.8][i])
                    Capsule().fill(rec.cancelHint ? Theme.accent : Theme.text.opacity(0.75)).frame(width: 3, height: max(4, h))
                        .animation(.linear(duration: 0.08), value: rec.level)
                }
            }
            .frame(height: 22)
            Text(String(format: "%d″", Int(rec.seconds))).font(Theme.mono(13, weight: .medium)).foregroundColor(Theme.text)
            Spacer()
            Text(rec.cancelHint ? "松手取消" : "上滑取消").font(Theme.round(12.5)).foregroundColor(rec.cancelHint ? Theme.accent : Theme.muted)
        }
        .frame(height: Composer.minH)
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
