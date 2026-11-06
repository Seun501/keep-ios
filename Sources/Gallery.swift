import SwiftUI
import AVFoundation
import Photos
import PhotosUI
import CryptoKit

// MARK: - Live 图与大图翻页（11-06 寻定）
// Live：她发 Live 图时静图照旧发给克，那 3 秒视频另传网关 /api/live 落 live/<静图哈希>.mov；
//       App 里图角标 LIVE、按住就播（带声，同语音条走 .playback）。克只看静图。
// 翻页：聊天＝消息流里她发的图、档案馆＝当天、相册＝同一册；放大时拖是挪图，没放大时左右拖是翻页。

struct GalleryItem: Equatable {
    var src: String
    var live: String? = nil
}

/// 静图的网关文件名哈希：和网关 _save_image 同一算法（jpeg 原字节 sha256 前 32 位），视频凭它对上静图
enum LiveHash {
    static func of(dataURL: String) -> String? {
        guard let comma = dataURL.firstIndex(of: ","), let d = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}

/// 从系统选图器的一项里取 Live 的那段视频（PHLivePhoto → pairedVideo 写进临时文件）；不是 Live 回 nil
enum LiveExtract {
    static func video(_ ip: NSItemProvider) async -> URL? {
        guard ip.canLoadObject(ofClass: PHLivePhoto.self) else { return nil }
        let lp: PHLivePhoto? = await withCheckedContinuation { c in
            ip.loadObject(ofClass: PHLivePhoto.self) { o, _ in c.resume(returning: o as? PHLivePhoto) }
        }
        guard let lp, let res = PHAssetResource.assetResources(for: lp).first(where: { $0.type == .pairedVideo }) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).mov")
        let ok: Bool = await withCheckedContinuation { c in
            let o = PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed = true   // iCloud 照片：视频不在本机时去取
            PHAssetResourceManager.default().writeData(for: res, toFile: out, options: o) { err in c.resume(returning: err == nil) }
        }
        return ok ? out : nil
    }
}

/// 视频本地缓存：Caches/live/<文件名>。发出去的那段直接搬进来，别人的第一次按住时下好
enum LiveCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("live", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static func path(_ src: String) -> URL { dir.appendingPathComponent((src as NSString).lastPathComponent) }
    static func fetch(_ src: String) async -> URL? {
        if src.hasPrefix("file://") { return URL(string: src) }
        let p = path(src)
        if FileManager.default.fileExists(atPath: p.path) { return p }
        guard let url = URL(string: src, relativeTo: Gateway.home) else { return nil }
        var r = URLRequest(url: url)
        if let token = Keychain.token, url.host == Gateway.home.host { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (tmp, resp) = try? await URLSession.shared.download(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? FileManager.default.removeItem(at: p)
        try? FileManager.default.moveItem(at: tmp, to: p)
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }
}

extension GatewayAPI {
    /// 传 Live 视频（?img＝静图哈希）。文件发之前已搬进 LiveCache（回显那条按住就能播，不等传完）
    static func uploadLive(file: URL, img: String) async throws {
        guard let token = Keychain.token else { throw Failure.unauthorized }
        var comps = URLComponents(url: Gateway.home.appendingPathComponent("api/live"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "img", value: img)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Failure.unauthorized }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
    }
}

extension LiveCache {
    /// 要发的那几张：图（dataURL）→ 视频。搬进缓存（名字＝网关上的名字），回 images 对齐的 lives 与待传清单
    static func stage(images: [String], videos: [String: URL]) -> (lives: [String], uploads: [(URL, String)]) {
        var lives: [String] = [], ups: [(URL, String)] = []
        for u in images {
            guard let v = videos[u], let h = LiveHash.of(dataURL: u) else { lives.append(""); continue }
            let src = "/uploads/live/\(h).mov", dst = path(src)
            if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.moveItem(at: v, to: dst) }
            guard FileManager.default.fileExists(atPath: dst.path) else { lives.append(""); continue }
            lives.append(src); ups.append((dst, h))
        }
        return (lives, ups)
    }
}

/// 按住播：按下去先下（缓存有就直接放），放到头或松手就退回静图
@MainActor
final class LivePlayer: ObservableObject {
    @Published var playing = false
    private(set) var player: AVPlayer? = nil
    private var want = false
    private var endObs: Any? = nil
    func start(_ src: String) {
        want = true
        Task {
            guard let file = await LiveCache.fetch(src), want else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)   // 带声（寻 11-06），同语音条
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = AVPlayer(url: file)
            if let o = endObs { NotificationCenter.default.removeObserver(o) }
            endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            player = p
            p.play()
            playing = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
    func stop() {
        want = false
        player?.pause()
        if playing { withAnimation(.easeOut(duration: 0.18)) { playing = false } }
        player = nil
        if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
    }
}

/// AVPlayerLayer 包一层
struct LiveVideoLayer: UIViewRepresentable {
    let player: AVPlayer
    var fill = false
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> V { let v = V(); v.isUserInteractionEnabled = false; v.backgroundColor = .clear; return v }
    func updateUIView(_ v: V, context: Context) {
        v.pl.player = player
        v.pl.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

/// 角标：同系统相册那枚——实心点＋细圈＋虚线外圈＋LIVE（线性画法，不描边不加阴影；垫一层淡暗底保证亮图上看得清）
struct LiveBadge: View {
    var compact = false
    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [1.2, 1.6])).frame(width: 12, height: 12)
                Circle().strokeBorder(lineWidth: 1).frame(width: 8, height: 8)
                Circle().frame(width: 3.5, height: 3.5)
            }
            if !compact { Text("LIVE").font(Theme.mono(9.5, weight: .medium)).tracking(0.6) }
        }
        .foregroundColor(.white.opacity(0.92))
        .padding(.horizontal, compact ? 4 : 6).padding(.vertical, 3)
        .background(Color.black.opacity(0.26), in: Capsule())
    }
}

/// 消息流小图上的 Live：左上角标＋按住就地播（松手停）；轻点照旧开大图
struct LiveHold: ViewModifier {
    let live: String?
    var radius: CGFloat
    @StateObject private var lp = LivePlayer()
    @ViewBuilder func body(content: Content) -> some View {
        if let live {
            content
                .overlay {
                    if lp.playing, let p = lp.player {
                        LiveVideoLayer(player: p, fill: true).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    }
                }
                .overlay(alignment: .topLeading) { LiveBadge(compact: true).padding(8).opacity(lp.playing ? 0 : 1).allowsHitTesting(false) }
                .onLongPressGesture(minimumDuration: 0.28, maximumDistance: 12, perform: { lp.start(live) },
                                    onPressingChanged: { if !$0 { lp.stop() } })
                .onDisappear { lp.stop() }
        } else {
            content
        }
    }
}

// MARK: - 大图翻页

/// 翻页＋捏合缩放＋双击放大＋Live 按住播。页面怎么画由调用方给（聊天走 StreamImageCache、相册走 GatewayImage）
struct ZoomPager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    var live: (Int) -> String?
    var onTap: () -> Void
    @ViewBuilder var page: (Int) -> Page
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dx: CGFloat = 0
    @StateObject private var lp = LivePlayer()
    private let gap: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let lo = max(0, index - 1), hi = max(lo, min(count - 1, index + 1))
            ZStack {
                ForEach(lo...hi, id: \.self) { i in
                    page(i)
                        .overlay { if i == index, lp.playing, let p = lp.player { LiveVideoLayer(player: p) } }   // 叠在页面自己的框上，和静图同一块
                        .frame(width: w, height: geo.size.height)
                    .scaleEffect(i == index ? scale : 1)
                    .offset(x: CGFloat(i - index) * (w + gap) + dx + (i == index ? offset.width : 0),
                            y: i == index ? offset.height : 0)
                }
            }
            .frame(width: w, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 8).onChanged { v in
                if scale > 1 {
                    offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                    return
                }
                var t = v.translation.width
                if (index == 0 && t > 0) || (index >= count - 1 && t < 0) { t /= 3 }   // 到头了：拖得动但带阻尼
                dx = t
            }.onEnded { v in
                if scale > 1 { lastOffset = offset; return }
                var ni = index
                let t = v.translation.width, pred = v.predictedEndTranslation.width
                if (t < -w * 0.18 || pred < -w * 0.5), index < count - 1 { ni += 1 }
                else if (t > w * 0.18 || pred > w * 0.5), index > 0 { ni -= 1 }
                withAnimation(.easeOut(duration: 0.22)) { index = ni; dx = 0 }
            })
            .simultaneousGesture(MagnificationGesture().onChanged { v in
                scale = min(6, max(1, lastScale * v)); if scale == 1 { offset = .zero; lastOffset = .zero }
            }.onEnded { _ in lastScale = scale })
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.28, maximumDistance: 12).onEnded { _ in
                if let s = live(index) { lp.start(s) }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in lp.stop() })   // 松手就停（长按本身不报松手）
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5 }; lastScale = scale }
            }
            .onTapGesture { onTap() }
        }
        .overlay(alignment: .topLeading) {
            if live(index) != nil {
                LiveBadge().padding(.leading, 16).padding(.top, 58).opacity(lp.playing ? 0 : 1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if count > 1 {   // 第几张（Cascadia Mono 小字，淡白）
                Text("\(index + 1) / \(count)").font(Theme.mono(12)).foregroundColor(.white.opacity(0.7)).padding(.top, 60).allowsHitTesting(false)
            }
        }
        .onChange(of: index) { _ in
            lp.stop(); scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
        .onDisappear { lp.stop() }
    }
}

/// 一页大图：先拿缓存垫着，再按 src 取（dataURL 直接解、/uploads 带口令头）
struct StreamFullImage: View {
    let src: String
    @State private var ui: UIImage?
    init(src: String) { self.src = src; _ui = State(initialValue: StreamImageCache.peek(src: src)) }
    var body: some View {
        Group {
            if let ui { Image(uiImage: ui).resizable().scaledToFit() }
            else { ProgressView().tint(.white) }
        }
        .task(id: src) { if ui == nil { ui = await StreamImageCache.load(src) } }
    }
}
