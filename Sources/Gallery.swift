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
    var orig: String? = nil     // 原图（11-06）：大图先垫压缩版、原图到了再换
}

/// 原图（11-06 寻定「以后发图每张都存原图」）：选图器给的原样文件（多为 HEIC），克那边照旧只拿 1568 那份
enum OrigExtract {
    static func data(_ ip: NSItemProvider) async -> (Data, String)? {
        let pick: [(String, String)] = [("public.heic", "heic"), ("public.jpeg", "jpg"), ("public.png", "png")]
        guard let (uti, ext) = pick.first(where: { ip.hasItemConformingToTypeIdentifier($0.0) }) else { return nil }
        return await withCheckedContinuation { c in
            ip.loadDataRepresentation(forTypeIdentifier: uti) { d, _ in c.resume(returning: d.map { ($0, ext) }) }
        }
    }
}

/// 静图的网关文件名哈希：和网关 _save_image 同一算法（jpeg 原字节 sha256 前 32 位），视频凭它对上静图
enum LiveHash {
    static func of(dataURL: String) -> String? {
        guard let comma = dataURL.firstIndex(of: ","), let d = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
    /// 已在网关上的图 /uploads/<哈希>.jpg → 哈希（相册给旧图配 Live 用）
    static func of(upload: String) -> String? {
        guard let r = upload.range(of: #"^/uploads/([0-9a-f]{32})\.(jpg|png|webp|gif)$"#, options: .regularExpression) else { return nil }
        return String(upload[r].dropFirst("/uploads/".count).prefix(32))
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
        trim()
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

extension GatewayAPI {
    static func uploadOrig(data: Data, img: String, ext: String) async throws {
        guard let token = Keychain.token else { throw Failure.unauthorized }
        var comps = URLComponents(url: Gateway.home.appendingPathComponent("api/orig"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "img", value: img), URLQueryItem(name: "ext", value: ext)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let (_, resp) = try await URLSession.shared.upload(for: req, from: data)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Failure.unauthorized }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
    }
}

extension LiveCache {
    /// 视频缓存超 150MB 从最旧的删（11-06 寻「手机下 Keep 越来越大」）
    static func trim(limit: Int = 150 * 1024 * 1024) {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]) else { return }
            var rows = items.map { u -> (URL, Int, Date) in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
                return (u, v?.fileSize ?? 0, v?.contentAccessDate ?? .distantPast)
            }
            var total = rows.reduce(0) { $0 + $1.1 }
            guard total > limit else { return }
            rows.sort { $0.2 < $1.2 }
            for r in rows where total > limit { try? fm.removeItem(at: r.0); total -= r.1 }
        }
    }
    /// 原图：发之前先落进看图的磁盘缓存（名字＝网关上的地址），回显那条点开就是原图；回 images 对齐的 origs 与待传清单
    static func stageOrigs(images: [String], origs: [String: (Data, String)]) -> (origs: [String], uploads: [(Data, String, String)]) {
        var out: [String] = [], ups: [(Data, String, String)] = []
        for u in images {
            guard let (d, ext) = origs[u], let h = LiveHash.of(dataURL: u),
                  let url = URL(string: "/uploads/orig/\(h).\(ext)", relativeTo: Gateway.home) else { out.append(""); continue }
            GatewayImageCache.Disk.write(url, d)
            out.append("/uploads/orig/\(h).\(ext)"); ups.append((d, h, ext))
        }
        return (out, ups)
    }
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
    var dim = false   // 发图前没点亮（11-07）
    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [1.2, 1.6])).frame(width: 12, height: 12)
                Circle().strokeBorder(lineWidth: 1).frame(width: 8, height: 8)
                Circle().frame(width: 3.5, height: 3.5)
                if dim { Rectangle().frame(width: 1.2, height: 15).rotationEffect(.degrees(-45)) }   // 11-07 寻：照微信那样，关着＝图标上一道斜杠
            }
            if !compact { Text("LIVE").font(Theme.mono(9.5, weight: .medium)).tracking(0.6) }
        }
        .foregroundColor(.white.opacity(dim ? 0.5 : 0.92))
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
    @State private var pinching = false
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dx: CGFloat = 0
    @State private var dy: CGFloat = 0          // 往下拖着退出（11-07）
    @State private var slop: CGSize = .zero     // 认出方向那一刻手指已走的距离：减掉它，图从原地起步不跳
    @State private var axis = 0                 // 这一拖：0 未定 1 横翻 2 竖拖退出 3 平移放大的图 -1 双指/作废
    @State private var downAt: Date? = nil
    @State private var holdTask: Task<Void, Never>? = nil
    @State private var holding = false
    @State private var lastTap: Date = .distantPast
    @State private var tapTask: Task<Void, Never>? = nil
    @StateObject private var lp = LivePlayer()
    private let gap: CGFloat = 18
    private let flip = Animation.interactiveSpring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.1)

    /// 一个手势管到底（11-07 寻：原来几个手势叠着把单击吃了，点图关不掉）：
    /// 轻点＝退出（双击放大，第二下 0.26 秒内来）；按住不动 0.28 秒＝播 Live、松手停；横拖翻页、竖拖往下退出；放大后拖＝平移。
    private func drag(_ w: CGFloat, _ h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { v in
            if downAt == nil {
                downAt = Date(); axis = 0; holding = false
                holdTask?.cancel()
                holdTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 280_000_000)
                    guard !Task.isCancelled, axis == 0, !pinching else { return }
                    holding = true
                    if let s = live(index) { lp.start(s) }
                }
            }
            if pinching { axis = -1; return }
            let t = v.translation
            if axis == 0, !holding, hypot(t.width, t.height) > 10 {
                holdTask?.cancel()
                axis = scale > 1 ? 3 : (abs(t.width) >= abs(t.height) ? 1 : (t.height > 0 ? 2 : -1))
                slop = axis == 3 ? .zero : t
            }
            switch axis {
            case 1:
                var x = t.width - slop.width
                if (index == 0 && x > 0) || (index >= count - 1 && x < 0) { x = x / (1 + abs(x) / (w * 0.35)) }   // 到头：越拖越沉，不是硬切三分之一
                dx = x
            case 2: dy = max(0, t.height - slop.height)
            case 3: offset = CGSize(width: lastOffset.width + t.width, height: lastOffset.height + t.height)
            default: break
            }
        }.onEnded { v in
            holdTask?.cancel()
            let held = holding, a = axis
            let quick = Date().timeIntervalSince(downAt ?? Date()) < 0.28
            downAt = nil; axis = 0; holding = false
            if held { lp.stop(); return }
            switch a {
            case 1:
                var ni = index
                let t = dx, vel = (v.predictedEndTranslation.width - v.translation.width) * 2   // SwiftUI 的预测≈速度×0.5 秒
                if (t < -w * 0.2 || vel < -500), index < count - 1 { ni += 1 }
                else if (t > w * 0.2 || vel > 500), index > 0 { ni -= 1 }
                // 先原地换页（画面不动），再带着手指的速度弹回 0：松手那下不顿、不硬切（11-07 寻：翻页太硬）
                let from = dx + CGFloat(ni - index) * (w + gap)
                index = ni; dx = from
                let k = abs(from) > 1 ? max(0, -vel / from) : 0
                // 11-07 寻：还是太快太硬 → 刚度 260→120（临界阻尼 2√k≈22），落定约慢一半，不回弹
                withAnimation(.interpolatingSpring(mass: 1, stiffness: 120, damping: 22, initialVelocity: min(k, 8))) { dx = 0 }
            case 2:
                if dy > h * 0.14 || v.predictedEndTranslation.height > h * 0.3 {
                    // 11-07 寻：下滑退出太僵 → 先顺着手往下滑出去、黑底一起淡掉，再关（原来松手当场关，画面一跳）
                    withAnimation(.easeOut(duration: 0.22)) { dy = h }
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 200_000_000); onTap() }
                }
                else { withAnimation(flip) { dy = 0 } }
            case 3: lastOffset = offset
            case 0 where quick && !pinching: tapped()
            default: break
            }
        }
    }

    private func tapped() {
        tapTask?.cancel()
        if Date().timeIntervalSince(lastTap) < 0.26 {   // 双击：放大／还原
            lastTap = .distantPast
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5 }
                lastScale = scale
            }
            return
        }
        lastTap = Date()
        tapTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 260_000_000)
            if !Task.isCancelled { onTap() }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let lo = max(0, index - 1), hi = max(lo, min(count - 1, index + 1))
            let shrink = 1 - min(dy / h, 1) * 0.35
            ZStack {
                ForEach(lo...hi, id: \.self) { i in
                    page(i)
                        .overlay { if i == index, lp.playing, let p = lp.player { LiveVideoLayer(player: p) } }   // 叠在页面自己的框上，和静图同一块
                        .frame(width: w, height: h)
                    .scaleEffect(i == index ? scale * shrink : 1)
                    .offset(x: CGFloat(i - index) * (w + gap) + dx + (i == index ? offset.width : 0),
                            y: i == index ? offset.height + dy : 0)
                    .opacity(i == index ? 1 : 1 - min(dy / (h * 0.25), 1))
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(drag(w, h))
            .simultaneousGesture(MagnificationGesture().onChanged { v in
                pinching = true; holdTask?.cancel()
                scale = min(6, max(1, lastScale * v)); if scale == 1 { offset = .zero; lastOffset = .zero }
            }.onEnded { _ in
                lastScale = scale
                Task { @MainActor in try? await Task.sleep(nanoseconds: 150_000_000); pinching = false }
            })
        }
        .overlay(alignment: .topLeading) {
            if live(index) != nil {
                LiveBadge().padding(.leading, 16).padding(.top, 58).opacity(lp.playing || dy > 0 ? 0 : 1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if count > 1 {   // 第几张（Cascadia Mono 小字，淡白）
                Text("\(index + 1) / \(count)").font(Theme.mono(12)).foregroundColor(.white.opacity(0.7)).padding(.top, 60)
                    .opacity(dy > 0 ? 0 : 1).allowsHitTesting(false)
            }
        }
        .preference(key: ViewerDismissKey.self, value: dy)
        .onChange(of: index) { _ in
            lp.stop(); scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
        .onDisappear { lp.stop(); holdTask?.cancel(); tapTask?.cancel() }
    }
}

/// 往下拖退出时，宿主按这个把黑底渐淡
struct ViewerDismissKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 一页大图：先拿缓存垫着（原图有就用原图，没到先垫压缩版），再按 src 取（dataURL 直接解、/uploads 带口令头）。
/// 一律按 2600 长边解（屏幕 3 倍够用）：原图常是 4032×3024，整张解开一张就近 50MB
struct StreamFullImage: View {
    let src: String
    var orig: String? = nil
    @State private var ui: UIImage?
    @State private var full = false
    private static let px = GatewayImageCache.fullPx
    init(src: String, orig: String? = nil) {
        self.src = src; self.orig = orig
        let o = orig.flatMap { StreamImageCache.peek(src: $0, maxPixel: Self.px) }
        _full = State(initialValue: o != nil || orig == nil)
        _ui = State(initialValue: o ?? StreamImageCache.peek(src: src, maxPixel: Self.px) ?? StreamImageCache.peek(src: src, maxPixel: 600))
    }
    var body: some View {
        Group {
            if let ui { Image(uiImage: ui).resizable().scaledToFit() }
            else { ProgressView().tint(.white) }
        }
        .task(id: src + (orig ?? "")) {
            if ui == nil || (orig == nil && !full) { ui = await StreamImageCache.load(src, maxPixel: Self.px) ?? ui }
            if let o = orig, !full, let big = await StreamImageCache.load(o, maxPixel: Self.px) { ui = big; full = true }
        }
    }
}
