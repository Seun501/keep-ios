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

/// 翻页＋捏合缩放＋双击放大＋Live 按住播。页面怎么画由调用方给（聊天走 StreamImageCache、相册走 GatewayImage）。
/// 11-07 寻：SwiftUI 手搓的翻页和下滑「还是不够顺」→ 换成系统自己的 UIScrollView：外层分页（翻页惯性、回弹＝系统原样），
/// 每页一个能缩放的 UIScrollView（捏合、双击、放大后拖＝系统原样）；下滑退出用 UIKit 弹簧。页面本身照旧是 SwiftUI。
struct ZoomPager<Page: View>: View {
    let count: Int
    @Binding var index: Int
    var live: (Int) -> String?
    var onTap: () -> Void
    @ViewBuilder var page: (Int) -> Page
    @StateObject private var model = PagerModel()
    @StateObject private var lp = LivePlayer()

    var body: some View {
        NativePager(count: count, index: $index, model: model, lp: lp, live: live, onTap: onTap, page: page)
            .overlay(alignment: .topLeading) {
                if live(index) != nil {
                    LiveBadge().padding(.leading, 16).padding(.top, 58).opacity(lp.playing || model.dy > 0 ? 0 : 1).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if count > 1 {   // 第几张（Cascadia Mono 小字，淡白）
                    Text("\(index + 1) / \(count)").font(Theme.mono(12)).foregroundColor(.white.opacity(0.7)).padding(.top, 60)
                        .opacity(model.dy > 0 ? 0 : 1).allowsHitTesting(false)
                }
            }
            .preference(key: ViewerDismissKey.self, value: model.dy)
            .onChange(of: index) { _ in lp.stop() }
            .onDisappear { lp.stop() }
    }
}

final class PagerModel: ObservableObject {
    @Published var dy: CGFloat = 0      // 往下拖了多远（宿主拿去淡黑底）
    @Published var current = 0
}

/// 一页：调用方的画面＋正在播的 Live 视频叠在同一块上
private struct PagerPage<P: View>: View {
    let i: Int
    @ObservedObject var model: PagerModel
    @ObservedObject var lp: LivePlayer
    let content: P
    var body: some View {
        content
            .overlay { if i == model.current, lp.playing, let p = lp.player { LiveVideoLayer(player: p) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NativePager<Page: View>: UIViewRepresentable {
    let count: Int
    @Binding var index: Int
    let model: PagerModel
    let lp: LivePlayer
    var live: (Int) -> String?
    var onTap: () -> Void
    var page: (Int) -> Page

    func makeUIView(context: Context) -> PagerView {
        let v = PagerView()
        wire(v)
        v.jump(to: index)
        return v
    }
    func updateUIView(_ v: PagerView, context: Context) {
        wire(v)
        if v.current != index { v.jump(to: index) } else { v.reload() }
    }
    private func wire(_ v: PagerView) {
        let model = model, lp = lp, page = page, live = live, binding = $index
        v.count = count
        v.makePage = { i in AnyView(PagerPage(i: i, model: model, lp: lp, content: page(i))) }
        v.onIndex = { i in
            DispatchQueue.main.async {   // 不在 SwiftUI 刷新中途改状态
                if model.current != i { model.current = i }
                if binding.wrappedValue != i { binding.wrappedValue = i }
            }
        }
        v.onTap = onTap
        v.onDrop = { d in model.dy = d }
        v.onHold = { [weak v] down in
            guard let v else { return }
            if down, let s = live(v.current) { lp.start(s) } else { lp.stop() }
        }
        v.canHold = { [weak v] in v.map { live($0.current) != nil } ?? false }
    }
}

final class PagerView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var count = 0 { didSet { if count != oldValue { setNeedsLayout() } } }
    var makePage: (Int) -> AnyView = { _ in AnyView(EmptyView()) }
    var onIndex: (Int) -> Void = { _ in }
    var onTap: () -> Void = {}
    var onDrop: (CGFloat) -> Void = { _ in }
    var onHold: (Bool) -> Void = { _ in }
    var canHold: () -> Bool = { false }
    private(set) var current = 0
    private let gap: CGFloat = 18
    private let pager = UIScrollView()
    private var cells: [Int: ZoomCell] = [:]
    private let dismissPan = UIPanGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private var dismissing = false
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        pager.isPagingEnabled = true
        pager.showsHorizontalScrollIndicator = false
        pager.showsVerticalScrollIndicator = false
        pager.contentInsetAdjustmentBehavior = .never
        pager.alwaysBounceVertical = false
        pager.backgroundColor = .clear
        pager.clipsToBounds = false
        pager.delegate = self
        addSubview(pager)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        hold.addTarget(self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.28
        hold.delegate = self
        single.require(toFail: double)
        single.require(toFail: hold)
        dismissPan.addTarget(self, action: #selector(panned(_:)))
        dismissPan.delegate = self
        pager.panGestureRecognizer.require(toFail: dismissPan)
        [single, double, hold, dismissPan].forEach(addGestureRecognizer)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var pageW: CGFloat { bounds.width + gap }
    private func frame(for i: Int) -> CGRect {
        CGRect(x: CGFloat(i) * pageW + gap / 2, y: 0, width: bounds.width, height: bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        let resized = bounds.size != lastSize
        lastSize = bounds.size
        pager.frame = CGRect(x: -gap / 2, y: 0, width: pageW, height: bounds.height)   // 页距 18：滚动框比屏幕宽一个页距
        pager.contentSize = CGSize(width: pageW * CGFloat(max(count, 1)), height: bounds.height)
        if resized {
            for (i, c) in cells { c.transform = .identity; c.frame = frame(for: i); c.relayout() }
            pager.contentOffset = CGPoint(x: CGFloat(current) * pageW, y: 0)
        }
        fill()
    }

    func jump(to i: Int) {
        guard count > 0 else { return }
        let i = max(0, min(count - 1, i))
        current = i
        if bounds.width > 0 { pager.contentOffset = CGPoint(x: CGFloat(i) * pageW, y: 0) }
        fill()
        onIndex(i)
    }
    func reload() { for (i, c) in cells { c.host.rootView = makePage(i) } }

    /// 只留当前页和左右各一页
    private func fill() {
        guard bounds.width > 0, count > 0 else { return }
        let want = Set(max(0, current - 1)...min(count - 1, current + 1))
        for (i, c) in cells where !want.contains(i) { c.removeFromSuperview(); cells[i] = nil }
        for i in want where cells[i] == nil {
            let c = ZoomCell(page: makePage(i))
            c.frame = frame(for: i)
            c.relayout()
            c.panGestureRecognizer.require(toFail: dismissPan)
            pager.addSubview(c)
            cells[i] = c
        }
    }

    // MARK: 翻页（系统分页）
    func scrollViewDidScroll(_ s: UIScrollView) {
        guard s === pager, bounds.width > 0, count > 0 else { return }
        let i = max(0, min(count - 1, Int((s.contentOffset.x / pageW).rounded())))
        if i != current { current = i; fill(); onIndex(i) }
    }
    func scrollViewDidEndDecelerating(_ s: UIScrollView) {
        guard s === pager else { return }
        for (i, c) in cells where i != current && c.zoomScale != 1 { c.setZoomScale(1, animated: false) }   // 翻走的那页还原
    }

    // MARK: 点、双击、按住
    @objc private func tapped() { if !dismissing { onTap() } }
    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard let c = cells[current] else { return }
        if c.zoomScale > 1.01 { c.setZoomScale(1, animated: true); return }
        let p = g.location(in: c.host.view), s: CGFloat = 2.5
        let w = c.bounds.width / s, h = c.bounds.height / s
        c.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }
    @objc private func held(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began: pager.isScrollEnabled = false; onHold(true)
        case .ended, .cancelled, .failed: pager.isScrollEnabled = true; onHold(false)
        default: break
        }
    }
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === dismissPan {
            guard let c = cells[current], c.zoomScale <= 1.01, !dismissing else { return false }
            let v = dismissPan.velocity(in: self)
            return v.y > 0 && v.y > abs(v.x)   // 只认往下的竖拖；横拖交给分页
        }
        if g === hold { return canHold() }
        return super.gestureRecognizerShouldBegin(g)
    }

    // MARK: 下滑退出（图跟手走、缩小，黑底一起淡；松手系统弹簧回位或顺势滑出）
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let c = cells[current] else { return }
        let t = g.translation(in: self), h = max(bounds.height, 1)
        switch g.state {
        case .began:
            dismissing = true
        case .changed:
            let dy = max(0, t.y)
            let s = 1 - min(dy / h, 1) * 0.35
            c.transform = CGAffineTransform(translationX: t.x, y: t.y).scaledBy(x: s, y: s)
            onDrop(dy)
        case .ended, .cancelled, .failed:
            let v = g.velocity(in: self), dy = max(0, t.y)
            if g.state == .ended && ((dy > h * 0.12 && v.y > -150) || v.y > 900) {
                let s = c.transform.a * 0.92
                let dur = TimeInterval(min(0.3, max(0.16, (h - dy) / max(v.y, 1))))
                UIView.animate(withDuration: dur, delay: 0, options: [.curveEaseOut]) {
                    c.transform = CGAffineTransform(translationX: t.x + v.x * 0.08, y: h * 0.9).scaledBy(x: s, y: s)
                }
                withAnimation(.easeOut(duration: dur)) { onDrop(h) }
                DispatchQueue.main.asyncAfter(deadline: .now() + dur * 0.85) { [weak self] in self?.onTap() }
            } else {
                let k = dy > 1 ? min(20, max(-20, -v.y / dy)) : 0
                UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: k,
                               options: [.allowUserInteraction]) { c.transform = .identity }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { onDrop(0) }
                dismissing = false
            }
        default: break
        }
    }
}

/// 一页能缩放的系统滚动框：捏合、双击、放大后拖都是系统原样
private final class ZoomCell: UIScrollView, UIScrollViewDelegate {
    let host: UIHostingController<AnyView>
    init(page: AnyView) {
        host = UIHostingController(rootView: page)
        super.init(frame: .zero)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        backgroundColor = .clear
        addSubview(host.view)
    }
    required init?(coder: NSCoder) { fatalError() }
    func relayout() {
        setZoomScale(1, animated: false)
        host.view.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
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
