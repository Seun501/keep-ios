import Foundation
import AVFoundation
import WatchKit

/// 表上的录音＋实时识别（09-15）：同手机端 VoiceRecorder 一个路子——麦克风当场开、去网关签票、直连腾讯 WebSocket，
/// 40ms 一帧推，字边说边回；同时把 16k 单声道 AAC 落文件，松手后传给网关（/api/voice，只存不转写）。
@MainActor
final class WatchRecorder: NSObject, ObservableObject {
    static let shared = WatchRecorder()
    @Published var recording = false
    @Published var level: CGFloat = 0
    @Published var seconds = 0.0
    @Published var cancelHint = false
    @Published var liveText = ""
    @Published var asrState = ""
    static let maxSeconds = 120.0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter? = nil
    private var file: AVAudioFile? = nil
    private var fileURL: URL? = nil
    private var ws: URLSessionWebSocketTask? = nil
    private var wsOpen = false
    private var pendingFrames: [Data] = []
    private var carry = Data()
    private var finished: [String] = []
    private var partial = ""
    private var gotFinal = false
    private var finalWaiter: CheckedContinuation<Void, Never>? = nil
    private var t0 = Date()
    private var ticker: Timer? = nil
    private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    struct Uploaded: Decodable { var url: String; var dur: Double; var text: String?; var tone: String? }   // text/tone 只在 transcribe=1 时有
    struct Result { var file: URL; var dur: Double; var text: String }

    func requestPermission() async -> Bool {
        if #available(watchOS 10, *) { return await AVAudioApplication.requestRecordPermission() }
        return await withCheckedContinuation { c in AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) } }
    }

    func start() -> Bool {
        guard !recording else { return true }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.record, mode: .default)
            try s.setActive(true)
        } catch { WatchDiag.send("voice: session \(error.localizedDescription)"); return false }
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0, let conv = AVAudioConverter(from: inFmt, to: Self.pcmFormat) else { WatchDiag.send("voice: no converter"); return false }
        converter = conv
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wvoice-\(Int(Date().timeIntervalSince1970)).m4a")
        do {
            file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000],
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        } catch { WatchDiag.send("voice: file \(error.localizedDescription)"); return false }
        fileURL = url
        finished = []; partial = ""; liveText = ""; asrState = ""; gotFinal = false; pendingFrames = []; carry = Data(); wsOpen = false
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFmt) { [weak self] buf, _ in
            guard let self else { return }
            var rms: Float = 0
            if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
                var sum: Float = 0
                for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
                rms = sqrt(sum / Float(buf.frameLength))
            }
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
        do { engine.prepare(); try engine.start() } catch { WatchDiag.send("voice: engine \(error.localizedDescription)"); input.removeTap(onBus: 0); return false }
        t0 = Date(); seconds = 0; level = 0; cancelHint = false; recording = true
        WKInterfaceDevice.current().play(.start)
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

    private func push(_ d: Data) {
        carry.append(d)
        while carry.count >= 1280 {
            let frame = carry.prefix(1280); carry.removeFirst(1280)
            if wsOpen, let ws { ws.send(.data(Data(frame))) { _ in } } else { pendingFrames.append(Data(frame)) }
        }
    }

    private struct Ticket: Decodable { var url: String }
    private func connect() async {
        guard let req = WatchChat.request("api/voice/ticket") else { asrState = "没票"; return }
        do {
            let (d, _) = try await URLSession.shared.data(for: req)
            let t = try JSONDecoder().decode(Ticket.self, from: d)
            guard let u = URL(string: t.url) else { throw URLError(.badURL) }
            let task = URLSession.shared.webSocketTask(with: u)
            ws = task
            task.resume()
            receiveLoop(task)
        } catch {
            WatchDiag.send("voice: ticket \(error.localizedDescription)")
            asrState = "识别没连上"
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] res in
            Task { @MainActor in
                guard let self, self.ws === task else { return }
                switch res {
                case .failure(let e):
                    if self.recording && !self.gotFinal { WatchDiag.send("voice: ws \((e as NSError).code) \(e.localizedDescription)"); self.asrState = "实时识别断了，松手后再听" }
                    self.finalWaiter?.resume(); self.finalWaiter = nil
                    return
                case .success(let m):
                    var txt = ""
                    if case .string(let s) = m { txt = s } else if case .data(let d) = m { txt = String(decoding: d, as: UTF8.self) }
                    if let d = txt.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        let code = j["code"] as? Int ?? 0
                        if code != 0 {
                            self.asrState = "识别出错 \(code)"
                        } else if let r = j["result"] as? [String: Any] {
                            let s = (r["voice_text_str"] as? String) ?? ""
                            if (r["slice_type"] as? Int) == 2 { self.finished.append(s); self.partial = "" } else { self.partial = s }
                            self.liveText = self.finished.joined() + self.partial
                        } else if !self.wsOpen {
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

    /// 松手：停麦、收文件、给腾讯发 end、等最后一句（最多 2.5 秒）。不到 1 秒当没录。
    func finish() async -> Result? {
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
        return Result(file: url, dur: dur, text: text)
    }

    func cancel() {
        guard recording else { return }
        stopCapture(); discardFile(); closeWS(); recording = false; cancelHint = false; liveText = ""
    }

    private func stopCapture() {
        ticker?.invalidate(); ticker = nil
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        file = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func discardFile() { if let u = fileURL { try? FileManager.default.removeItem(at: u) }; fileURL = nil }
    private func closeWS() { ws?.cancel(with: .normalClosure, reason: nil); ws = nil; wsOpen = false; pendingFrames = [] }

    /// m4a 整段 POST 给网关落盘（transcribe=false：只存，同手机二版；true：网关转写＋写语气，回 text/tone——
    /// 09-21 寻「表上无法语音转文字」：表上直连腾讯的 WebSocket 一开就断（diag：ws 似乎已断开与互联网的连接），没出字就走这条）
    static func upload(file: URL, dur: Double, transcribe: Bool = false) async throws -> Uploaded {
        guard let token = WatchKeychain.token else { throw URLError(.userAuthenticationRequired) }
        var comps = URLComponents(url: WatchGateway.home.appendingPathComponent("api/voice"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "dur", value: String(format: "%.1f", dur)), URLQueryItem(name: "transcribe", value: transcribe ? "1" : "0")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Data(contentsOf: file)
        req.timeoutInterval = transcribe ? 90 : 60   // 转写要等 Gemini（网关那头 45 秒顶）
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Uploaded.self, from: data)
    }
}
