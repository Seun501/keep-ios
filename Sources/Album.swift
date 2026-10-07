import SwiftUI
import ImageIO
import CryptoKit

// MARK: - 相册（2026-08-31 寻定稿改版：Gallery 总览 + 分册内页 + 全图查看）

struct Photo: Decodable, Identifiable {
    var img: String
    var desc: String?
    var intro: String?
    var book: String?
    var ts: String?
    var src: String?
    var surfUrl: String?
    var no: Int?
    var pid: Int?      // 照片的永久编号（09-12）：克口中的 #N——和他说「哪张」就靠它
    enum CodingKeys: String, CodingKey { case img, desc, intro, book, ts, src, no, pid, surfUrl = "surf_url" }
    var id: String { img + (ts ?? "") }
    var url: URL? { img.hasPrefix("http") ? URL(string: img) : URL(string: img, relativeTo: Gateway.home)?.absoluteURL }
}

struct AlbumPayload: Decodable {
    var photos: [Photo]
    var pins: [String]?
    var intros: [String: String]?
}

@MainActor
final class AlbumModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var pins: [String] = []
    @Published var intros: [String: String] = [:]
    @Published var loaded = false
    @Published var error: String? = nil

    func refresh() async {
        if Preview.on {
            if let d = Preview.json("preview_album"), let p = try? JSONDecoder().decode(AlbumPayload.self, from: d) {
                photos = p.photos; pins = p.pins ?? []; intros = p.intros ?? [:]
            }
            loaded = true; return
        }
        guard let token = Keychain.token else { return }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/album"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { error = "相册没翻开（连不上）"; return }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let p = try? JSONDecoder().decode(AlbumPayload.self, from: d) else {
            error = "相册没翻开（\((resp as? HTTPURLResponse)?.statusCode ?? 0)）"; return
        }
        photos = p.photos; pins = p.pins ?? []; intros = p.intros ?? [:]; loaded = true
    }
    /// 置顶在前，其余保持出场顺序；未分册（空名）排最后
    var order: [String] {
        var seen: [String] = []
        for p in photos { let k = p.book ?? ""; if !seen.contains(k) { seen.append(k) } }
        let named = seen.filter { !$0.isEmpty }.sorted { (pins.contains($0) ? 1 : 0) > (pins.contains($1) ? 1 : 0) }
        return named + (seen.contains("") ? [""] : [])
    }
    func photos(in book: String) -> [Photo] { photos.filter { ($0.book ?? "") == book }.reversed() }   // 新的在前
    func togglePin(_ book: String) {
        let on = !pins.contains(book)
        pins = on ? pins + [book] : pins.filter { $0 != book }
        guard !Preview.on, let token = Keychain.token else { return }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/album/pin"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["book": book, "pinned": on])
        Task { _ = try? await URLSession.shared.data(for: r) }
    }
}

/// 网关上的图（带口令头）：相册与档案的附图都走这里。
/// ⚠️ 里面的 Image 是 scaledToFill/Fit，本身没有尺寸——外面必须给定 frame（寻验 09-04 相册整页都是原尺寸大图，就是没给框）
struct GatewayImage<Placeholder: View>: View {
    let url: URL?
    var fill = true
    var maxPixel: CGFloat = 0            // >0＝按这个长边解码成小图（缩略格/瀑布用，别把整张原图塞进内存）
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage? = nil
    var body: some View {
        Group {
            if let image {
                if fill { Image(uiImage: image).resizable().scaledToFill() } else { Image(uiImage: image).resizable().scaledToFit() }
            } else { placeholder() }
        }
        .task(id: url) { image = await GatewayImageCache.load(url, maxPixel: maxPixel) }
    }
}
/// 按真实比例装进给定宽度（瀑布列/缩略）：先拿到图再定高，没拿到先按 4:3 占位
struct FitImage: View {
    let url: URL?
    let width: CGFloat
    var radius: CGFloat = 12
    @State private var image: UIImage? = nil
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().frame(width: width, height: (width * image.size.height / max(image.size.width, 1)).rounded())
            } else { Theme.panel.frame(width: width, height: (width * 0.75).rounded()) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: url) { image = await GatewayImageCache.load(url, maxPixel: GatewayImageCache.waterfallPx) }
    }
}
/// 相册/档案的图：内存缓存 → 磁盘缓存（Caches/gwimg，App 退出再开也不用重下）→ 网关。
/// 解码在后台线程，缩略按长边降采样（寻验 09-04：相册加载慢——原来每次进相册都整张原图重下、再在主线程解码）
enum GatewayImageCache {
    static let thumbPx: CGFloat = 480        // 总览三格（≈110pt）
    static let waterfallPx: CGFloat = 720    // 分册两列（≈170pt）
    static let soloPx: CGFloat = 1200        // 当天独一张的横图铺满两列（≈374pt）
    static let fullPx: CGFloat = 2600        // 看图器（屏幕 3 倍够用；原图有时上万像素）
    static let shared: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 400; c.totalCostLimit = 180 * 1024 * 1024; return c }()
    private static func key(_ url: URL, _ px: CGFloat) -> NSString { "\(url.absoluteString)#\(Int(px))" as NSString }
    static func peek(_ url: URL?, maxPixel: CGFloat = 0) -> UIImage? { url.flatMap { shared.object(forKey: key($0, maxPixel)) } }
    /// 已经解过的任何一档（缩略也行）——看图器开门先拿它垫着，原图到了再换
    static func peekAny(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        for px in [fullPx, soloPx, waterfallPx, thumbPx, 0] { if let c = shared.object(forKey: key(url, px)) { return c } }
        return nil
    }
    static func load(_ url: URL?, maxPixel: CGFloat = 0) async -> UIImage? {
        guard let url else { return nil }
        if let c = shared.object(forKey: key(url, maxPixel)) { return c }
        var data = Disk.read(url)
        if data == nil {
            var r = URLRequest(url: url)
            if let token = Keychain.token, url.host == Gateway.home.host { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return nil }
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { return nil }
            data = d
            if url.host == Gateway.home.host { Disk.write(url, d) }   // 只落网关上的图（data: 图不走这里）
        }
        guard let d = data else { return nil }
        let px = maxPixel
        guard let ui = await Task.detached(priority: .userInitiated, operation: { decode(d, maxPixel: px) }).value else { return nil }
        shared.setObject(ui, forKey: key(url, maxPixel), cost: Int(ui.size.width * ui.size.height * ui.scale * ui.scale * 4))
        return ui
    }
    nonisolated private static func decode(_ d: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return UIImage(data: d) }
        var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceCreateThumbnailFromImageAlways: true]
        if maxPixel > 0 { opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel }
        else if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat {
            opts[kCGImageSourceThumbnailMaxPixelSize] = Swift.max(w, h)   // 不缩，但走同一条解码路（已解好的位图，上屏不再卡）
        }
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return UIImage(cgImage: cg) }
        return UIImage(data: d)
    }
    /// 磁盘缓存：文件名＝地址的 SHA256；上限约 200MB，超了从最旧的删
    enum Disk {
        private static let dir: URL = {
            let d = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("gwimg", isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }()
        private static func path(_ url: URL) -> URL {
            let h = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            return dir.appendingPathComponent(h)
        }
        static func read(_ url: URL) -> Data? { try? Data(contentsOf: path(url)) }
        static func write(_ url: URL, _ d: Data) {
            try? d.write(to: path(url), options: .atomic)
            trimIfNeeded()
        }
        private static var writes = 0
        private static func trimIfNeeded() {
            writes += 1; guard writes % 40 == 0 else { return }
            DispatchQueue.global(qos: .utility).async {
                let fm = FileManager.default
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
                var files = items.compactMap { u -> (URL, Int, Date)? in
                    guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    return (u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
                }
                var total = files.reduce(0) { $0 + $1.1 }
                files.sort { $0.2 < $1.2 }
                for f in files where total > 200 * 1024 * 1024 { try? fm.removeItem(at: f.0); total -= f.1 }
            }
        }
    }
}

struct AlbumScreen: View {
    var onBack: () -> Void
    var onArchive: (String, Int) -> Void = { _, _ in }   // 跳档案馆那天那条（ⓘ 里「聊天 #N」）
    @StateObject private var m = AlbumModel()
    @State private var book: String? = nil
    @State private var lightbox: Photo? = nil

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { if book != nil { book = nil } else { onBack() } } label: {
                        BackChevron()
                    }.buttonStyle(.plain).padding(.leading, -8)
                    Text(book == nil ? "相册" : "").font(Theme.round(14)).foregroundColor(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                OrangeScroll(name: "album") {
                    if let e = m.error { empty(e) }
                    else if !m.loaded { empty("翻相册中…") }
                    else if let b = book { bookPage(b) }
                    else { home }
                }
            }
            if let p = lightbox { Lightbox(p: p, onClose: { lightbox = nil }, onArchive: { d, n in lightbox = nil; onArchive(d, n) }).zIndex(80) }
        }
        .background(EdgeSwipe(onBack: { if book != nil { book = nil } else { onBack() } }))
        .task {
            await m.refresh()
            if Preview.on {
                if Preview.screen == "albumbook" || Preview.screen == "albumlb" { book = m.order.first }
                if Preview.screen == "albumlb" { lightbox = m.photos.first }
            }
        }
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(Theme.round(13.5)).lineSpacing(6).multilineTextAlignment(.center).foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity).padding(.top, 60)
    }

    /// Gallery 总览（.gal-*）
    @ViewBuilder private var home: some View {
        if m.photos.isEmpty {
            empty("相册还空着\n这里只放克亲手收藏的照片")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Gallery").font(.custom("Georgia-Bold", size: 40)).tracking(0.4).foregroundColor(Theme.text).padding(.top, 8).padding(.horizontal, 24)
                let named = m.order.filter { !$0.isEmpty }.count
                Text("他收着的 · \(m.photos.count) 张" + (named > 0 ? " · \(named) 个相册" : "")).font(Theme.round(12)).tracking(0.24).foregroundColor(Theme.muted).padding(.top, 10).padding(.horizontal, 24)
                Text("最好看的那张是你。").font(Theme.serif(14.5)).italic().lineSpacing(4).foregroundColor(Theme.muted).padding(.top, 14).padding(.horizontal, 24)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(m.order, id: \.self) { k in
                        let ph = m.photos(in: k)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(k.isEmpty ? "未分册" : k).font(Theme.georgiaCJK(24)).foregroundColor(Theme.text)   // 中文回落思源宋（寻验 09-04）
                                if !k.isEmpty && m.pins.contains(k) { Text("★").font(Theme.ui(14)).foregroundColor(Theme.dyn(0xE0A896, 0xC98A76)).offset(y: -2) }
                                Spacer()
                                Text("\(ph.count)").font(Theme.round(13.5)).foregroundColor(Theme.muted)
                            }
                            if !k.isEmpty, let it = m.intros[k], !it.isEmpty {
                                Text(it).font(Theme.serif(13.5)).italic().lineSpacing(3.5).foregroundColor(Theme.muted).padding(.top, 7)
                            }
                            let show = Array(ph.prefix(3))
                            let cw = ((UIScreen.main.bounds.width - 48 - 12) / 3).rounded(.down)   // 三格正方：页边 20+4，格距 6
                            HStack(spacing: 6) {
                                ForEach(Array(show.enumerated()), id: \.offset) { i, p in
                                    ZStack {
                                        Theme.panel
                                        GatewayImage(url: p.url, maxPixel: GatewayImageCache.thumbPx) { Theme.panel }.frame(width: cw, height: cw).clipped()
                                        if i == show.count - 1 && ph.count > show.count {
                                            Wax.ink.opacity(0.38)
                                            Text("+\(ph.count - show.count + 1)").font(.custom("Georgia", size: 19)).foregroundColor(.white)
                                        }
                                    }
                                    .frame(width: cw, height: cw)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                if show.count < 3 { ForEach(0..<(3 - show.count), id: \.self) { _ in Color.clear.frame(width: cw, height: cw) } }
                            }
                            .padding(.top, 12)
                        }
                        .padding(EdgeInsets(top: 26, leading: 4, bottom: 4, trailing: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { book = k }
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 20, bottom: 20, trailing: 20))
            }
            .padding(.bottom, 40)
        }
    }

    /// 分册内页（.gd-*）：按日分组，两列瀑布
    private func bookPage(_ k: String) -> some View {
        let ph = m.photos(in: k)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(k.isEmpty ? "未分册" : k).font(Theme.georgiaCJK(34)).foregroundColor(Theme.text)
                if !k.isEmpty {
                    Text("★").font(Theme.ui(17)).foregroundColor(m.pins.contains(k) ? Theme.dyn(0xE0A896, 0xC98A76) : Theme.border)
                        .onTapGesture { m.togglePin(k) }   // 你点的：置顶/取消
                }
            }
            .padding(.top, 4).padding(.horizontal, 24)
            Text("\(ph.count) photos").font(Theme.round(12.5)).tracking(0.5).foregroundColor(Theme.muted).padding(.top, 10).padding(.horizontal, 24)
            if !k.isEmpty, let it = m.intros[k], !it.isEmpty {
                Text(it).font(Theme.serif(14)).italic().lineSpacing(4).foregroundColor(Theme.muted).padding(.top, 12).padding(.horizontal, 24)
            }
            if ph.isEmpty { empty("这一册还空着") }
            ForEach(dayGroups(ph), id: \.0) { day, arr in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(day.suffix(2))).font(.custom("Georgia-Bold", size: 28)).foregroundColor(Theme.accent)
                        Text("/" + monShort(day)).font(Theme.round(12)).tracking(1).foregroundColor(Theme.muted)
                    }.padding(.horizontal, 4).padding(.bottom, 12)
                    if arr.count == 1 {   // 当天独一张（寻 09-13）：横图铺满两列那么宽、按原比例定高；竖图/方图照旧占一列
                        SoloPhoto(p: arr[0], colW: Self.colW, fullW: Self.colW * 2 + 14, onTap: { lightbox = arr[0] })
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            column(arr.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element })
                            column(arr.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element })
                        }
                    }
                }
                .padding(EdgeInsets(top: 28, leading: 20, bottom: 0, trailing: 20))
            }
        }
        .padding(.bottom, 40)
    }
    static let colW = ((UIScreen.main.bounds.width - 40 - 14) / 2).rounded(.down)   // 两列瀑布：页边 20、列距 14
    private func column(_ arr: [Photo]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(arr) { p in
                VStack(alignment: .leading, spacing: 0) {
                    FitImage(url: p.url, width: Self.colW, radius: 12)
                        .onTapGesture { lightbox = p }
                    Self.caption(p)
                }
            }
        }
        .frame(width: Self.colW)
    }
    /// 图下的名字 / 简介 / 冲浪来源（两列与独张共用）
    @ViewBuilder static func caption(_ p: Photo) -> some View {
        Text((p.desc?.isEmpty == false) ? p.desc! : "（还没起名字）").font(Theme.serif(14, weight: .semibold)).lineSpacing(3).foregroundColor(Theme.text).padding(.top, 8).padding(.horizontal, 2)
        if let n = p.intro, !n.isEmpty { Text(n).font(Theme.serif(13)).lineSpacing(3.5).foregroundColor(Theme.muted).padding(.top, 3).padding(.horizontal, 2) }
        if p.src == "surf", let u = p.surfUrl, let url = URL(string: u) {
            Link("冲浪存的 ↗", destination: url).font(Theme.round(11)).foregroundColor(Theme.muted).padding(.top, 5).padding(.horizontal, 2)
        }
    }
    private func dayGroups(_ ph: [Photo]) -> [(String, [Photo])] {
        var out: [(String, [Photo])] = []
        for p in ph {
            let day = String((p.ts ?? "").prefix(10))
            if let last = out.last, last.0 == day { out[out.count - 1].1.append(p) } else { out.append((day, [p])) }
        }
        return out
    }
    private func monShort(_ day: String) -> String {
        let mons = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        if let m = Int(day.dropFirst(5).prefix(2)), m >= 1, m <= 12 { return mons[m - 1] }
        return String(day.dropFirst(5).prefix(2))
    }
}

/// 当天独一张：先拿到图再定宽——横图（宽＞高）铺满两列那么宽，竖图/方图占一列；高按原比例。没拿到先按一列 4:3 占位
struct SoloPhoto: View {
    let p: Photo
    let colW: CGFloat
    let fullW: CGFloat
    var onTap: () -> Void
    @State private var image: UIImage? = nil
    var body: some View {
        let wide = image.map { $0.size.width > $0.size.height } ?? false
        let w = wide ? fullW : colW
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let image { Image(uiImage: image).resizable().frame(width: w, height: (w * image.size.height / max(image.size.width, 1)).rounded()) }
                else { Theme.panel.frame(width: colW, height: (colW * 0.75).rounded()) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture(perform: onTap)
            AlbumScreen.caption(p)
        }
        .frame(width: w, alignment: .leading)
        .task(id: p.url) { image = await GatewayImageCache.load(p.url, maxPixel: GatewayImageCache.soloPx) }
    }
}

/// 全图查看：捏合缩放、双击 1x⇄2.5x、放大后拖动；ⓘ 掀信息条；单点空处收信息条/关闭
struct Lightbox: View {
    let p: Photo
    var onClose: () -> Void
    var onArchive: (String, Int) -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var sheet = false
    @State private var sheetDrag: CGFloat = 0
    var body: some View {
        ZStack {
            // 点图外的暗处也能退（寻验 09-04：原来只按图本体才关）；信息条开着先收信息条
            Color(red: 18/255, green: 18/255, blue: 17/255).opacity(0.96).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if sheet { sheet = false } else { onClose() } }
            // 开门先拿列表里已解好的缩略垫着（立刻有图），大图到了再换
            GatewayImage(url: p.url, fill: false, maxPixel: GatewayImageCache.fullPx) {
                if let t = GatewayImageCache.peekAny(p.url) { Image(uiImage: t).resizable().scaledToFit() } else { ProgressView().tint(.white) }
            }
                .frame(maxWidth: UIScreen.main.bounds.width * 0.96, maxHeight: UIScreen.main.bounds.height * 0.88)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .scaleEffect(scale)
                .offset(offset)
                .gesture(MagnificationGesture().onChanged { v in scale = min(6, max(1, lastScale * v)); if scale == 1 { offset = .zero; lastOffset = .zero } }
                    .onEnded { _ in lastScale = scale })
                .simultaneousGesture(DragGesture().onChanged { v in
                    guard scale > 1 else { return }
                    offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                }.onEnded { _ in lastOffset = offset })
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) { if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5 }; lastScale = scale }
                }
                .onTapGesture { if sheet { sheet = false } else { onClose() } }
            VStack {
                Spacer()
                if sheet {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // 永久编号（寻 09-13：和克讲「哪张」要看得见）：同档案馆的 #N 小签，长按抄进剪贴板
                            if let n = p.pid, n > 0 { NoTag("#\(n)", flash: false) }
                            Text((p.desc?.isEmpty == false) ? p.desc! : "（还没起名字）").font(Theme.serif(17, weight: .bold)).lineSpacing(4).foregroundColor(Theme.text)
                        }
                        if let c = p.intro, !c.isEmpty { RichText(attr: MD.keNS(c, size: 15.5, weight: .regular, lineHeight: 1.65)).padding(.top, 6) }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(when(p.ts))
                            HStack(spacing: 0) {
                                Text("来源 · ")
                                if p.src == "surf" {
                                    if let u = p.surfUrl, let url = URL(string: u) { Link("冲浪存的 · 原网页 ↗", destination: url).foregroundColor(Theme.accent) }
                                    else { Text("冲浪存的 · 原网页 ↗").foregroundColor(Theme.accent) }
                                } else if let n = p.no, n > 0 {
                                    Text("聊天 #\(n)").foregroundColor(Theme.accent).onTapGesture { onArchive(String((p.ts ?? "").prefix(10)), n) }
                                } else { Text("聊天") }
                            }
                        }
                        .font(Theme.round(11.5)).lineSpacing(6).foregroundColor(Theme.muted).padding(.top, 32)   // 时间/来源离描述空两行（寻验 09-04）
                    }
                    .padding(EdgeInsets(top: 18, leading: 22, bottom: 20, trailing: 22))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bg, in: UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
                    .offset(y: max(0, sheetDrag))
                    .gesture(DragGesture(minimumDistance: 6).onChanged { v in sheetDrag = v.translation.height }
                        .onEnded { v in if v.translation.height > 60 { sheet = false }; sheetDrag = 0 })   // 往下一划收起（寻验 09-04：往下滑得卡）
                    .transition(.move(edge: .bottom))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(.easeOut(duration: 0.26), value: sheet)
            Button { sheet.toggle() } label: {
                Text("i").font(.custom("Georgia-Italic", size: 17)).foregroundColor(.white.opacity(0.85))
                    .frame(width: 34, height: 34).background(Color.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 18).padding(.bottom, 18)
        }
        .background(EdgeSwipe(onBack: onClose))
    }
    private func when(_ ts: String?) -> String {
        guard let d = ts.flatMap(TimeFmt.parse) else { return "" }
        let c = Calendar.current
        return "\(c.component(.year, from: d))年\(c.component(.month, from: d))月\(c.component(.day, from: d))日 " + TimeFmt.hm(d)
    }
}

// MARK: - 「记忆」页（2026-08-29 寻定：克的 system prompt 全部对她可见）——注入层 + 工具清单，卡面照留言板裁

struct MemPayload: Decodable {
    struct Layer: Decodable { var title: String; var source: String?; var chars: Int?; var content: String }
    struct Tool: Decodable {
        struct Param: Decodable { var name: String; var required: Bool?; var desc: String? }
        var name: String; var description: String?; var params: [Param]?; var folded: Bool?
    }
    var total_chars: Int?
    var layers: [Layer]?
    var staging: [String]?
    var tools: [Tool]?
}

/// 问寻卡（10-03）：记忆整理时想问寻的是非题。GET api/askxun / POST api/askxun/answer 都回这个形状
struct AskXun: Decodable {
    struct Q: Decodable {
        var id: Int
        var q: String
        var title: String?
        var status: String?
        var answer: String?
        var note: String?
        var answered_at: String?
        var key: String { "ask-\(id)" }   // 懒列表身份别用裸 Int，免得和别组撞
    }
    var open: [Q]?
    var answered: [Q]?
}

struct MemScreen: View {
    var onBack: () -> Void
    var onArchive: (String, Int) -> Void = { _, _ in }   // 桶栏点「聊天 #N」去档案馆那一条（10-05）
    @State private var data: MemPayload? = nil
    @State private var failed = false
    @State private var open: Set<String> = []
    @State private var ask: AskXun? = nil   // 拉不到就是 nil：问寻栏整栏不出现，不影响注入层
    @State private var doneOpen = Preview.on && Preview.screen == "askpick"   // 答过的平时折成一行（寻 10-03 选乙）
    // 底栏三栏（寻 10-01 过目样式）：注入 / 词条 / 日子；右上角那句小字随栏换
    @State private var tab: String = {
        switch Preview.on ? Preview.screen : "" {
        case "memword", "memedit": return "word"
        case "memday", "memdayadd": return "day"
        case "membk", "membkopen", "membkmon", "membkq": return "bk"
        case "memmf", "memmfdoc", "memmfpeek": return "mf"
        case "mem", "askpick": return "inj"
        default: return "bk"   // 寻 10-05：记忆页默认进桶栏
        }
    }()
    @StateObject private var wm = WordsModel()
    @StateObject private var dm = DatesModel()
    @StateObject private var bm = BucketsModel()
    @StateObject private var mm = MastersModel()
    @State private var masterOpen: String? = Preview.on && ["memmfdoc", "memmfpeek"].contains(Preview.screen) ? "寻的身体与健康" : nil
    @State private var wordEdit: WordDraft? = nil
    @State private var dayAdd = false
    private let motto = ["inj": "他每天醒来就看得到的", "bk": "他记下的每一件事", "mf": "他长久知道的那些事", "word": "你提到时，递给他的那一行", "day": "早安卡提前三天开始提"]

    var body: some View {
        ZStack {
            Theme.boardBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { onBack() } label: { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
                    Spacer()
                    Text(motto[tab] ?? "").font(Theme.cjk(13.5, weight: .medium)).tracking(1)
                        .foregroundColor(Theme.muted).offset(y: 5)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                OrangeScroll(name: "mem-" + tab) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        switch tab {
                        case "word": WordsTab(m: wm, onEdit: { wordEdit = $0 })
                        case "day": DatesTab(m: dm, onAdd: { dayAdd = true })
                        case "bk": BucketsTab(m: bm, onArchive: onArchive)
                        case "mf": MastersTab(m: mm, onOpen: { n in withAnimation(.easeOut(duration: 0.26)) { masterOpen = n } })
                        default: injection
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
                }
                .id(tab)   // 换栏从顶上看起
                tabs
            }
            .ignoresSafeArea(.keyboard)
            if let d = wordEdit { WordSheet(m: wm, d: d, onClose: { wordEdit = nil }).id(d.id).zIndex(80) }
            if dayAdd { DaySheet(m: dm, onClose: { dayAdd = false }).zIndex(80) }
            if let n = masterOpen {
                MasterPage(name: n, m: mm, buckets: bm, onBack: { withAnimation(.easeOut(duration: 0.26)) { masterOpen = nil } }, onArchive: onArchive)
                    .transition(.move(edge: .trailing)).zIndex(90)
            }
        }
        .animation(.easeOut(duration: 0.24), value: wordEdit?.id)
        .animation(.easeOut(duration: 0.24), value: dayAdd)
        .background(EdgeSwipe(onBack: onBack))
        .task {
            async let a: Void = loadAsk()   // 问寻、注入层、词条、日子并行拉
            async let w: Void = wm.load()
            async let dd: Void = dm.load()
            async let bb: Void = bm.load()
            async let mf: Void = mm.load()
            await load()
            await a; await w; await dd; await bb; await mf
            if Preview.on && Preview.screen == "memedit", let g = wm.data?.groups.first, let s = g.sections.first, let it = s.items.first {
                wordEdit = WordDraft(file: g.file, section: s.title, names: it.names.joined(separator: " / "), desc: it.desc, old: (g.file, it.line))
            }
            if Preview.on && Preview.screen == "memdayadd" { dayAdd = true }
        }
    }
    /// 注入栏（样式稿 ①）：问寻栏在最上；卡片一样高，只有名字和字数，点开才展开全文；工具分「完全注入」「折叠」两段
    @ViewBuilder private var injection: some View {
        if data != nil || failed { askSection }
        if failed { MemEmpty("没拿到数据，退出来再进一次试试") }
        else if let d = data {
            let layers = d.layers ?? []
            SecTitle("注入层 · \(fmt(d.total_chars ?? 0))字")
            ForEach(Array(layers.enumerated()), id: \.offset) { i, l in
                card("L\(i)", title: layerName(l, layers), side: "\(fmt(l.chars ?? 0))字", full: l.content)
            }
            if let s = d.staging, !s.isEmpty {
                Text("待班车：" + s.joined(separator: "、") + "——明晨随裁窗换入").font(Theme.round(11)).tracking(0.44).lineSpacing(4).foregroundColor(Theme.muted).padding(.horizontal, 2).padding(.top, -2)
            }
            let tools = d.tools ?? []
            let full = tools.filter { $0.folded != true }
            let folded = tools.filter { $0.folded == true }
            if !full.isEmpty {
                SecTitle((folded.isEmpty ? "工具 · " : "工具 · 完全注入 · ") + "\(full.count)件 · \(fmt(chars(full)))字")
                ForEach(full, id: \.name) { t in card("T-" + t.name, title: t.name, side: "\(fmt(toolFull(t).count))字", full: toolFull(t)) }
            }
            if !folded.isEmpty {
                SecTitle("工具 · 折叠 · \(folded.count)件 · \(fmt(chars(folded)))字")
                ForEach(folded, id: \.name) { t in card("T-" + t.name, title: t.name, side: "\(fmt(toolFull(t).count))字", full: toolFull(t)) }
            }
        } else { MemEmpty("加载中…") }
    }
    private func chars(_ ts: [MemPayload.Tool]) -> Int { ts.map { toolFull($0).count }.reduce(0, +) }
    /// 同名的层（几份叙事文件都叫「叙事文件」）后面带上文件名，免得几张卡一模一样
    private func layerName(_ l: MemPayload.Layer, _ all: [MemPayload.Layer]) -> String {
        guard all.filter({ $0.title == l.title }).count > 1 else { return l.title }
        let file = (l.source ?? "").split(separator: "/").last.map(String.init) ?? ""
        return file.isEmpty ? l.title : l.title + " · " + file
    }
    /// 底栏三栏（照留言板 #notesTabs）：选中＝赤陶正圆托白线图标、往上冒、外圈页底色；字加粗
    private var tabs: some View {
        HStack(spacing: 0) {
            tabBtn("inj", "注入", "tabLayer")
            tabBtn("mf", "主文件", "tool-scroll")
            tabBtn("bk", "桶", "tool-archive")
            tabBtn("word", "词条", "tabWord")
            tabBtn("day", "日子", "tabDay")
        }
        .padding(.top, 3).padding(.horizontal, 4).padding(.bottom, 1)
        .background(Theme.card.ignoresSafeArea(edges: .bottom))
    }
    private func tabBtn(_ key: String, _ label: String, _ icon: String) -> some View {
        let on = tab == key
        return Button { tab = key } label: {
            VStack(spacing: 0) {
                Image(icon).renderingMode(.template).resizable().frame(width: 21, height: 21)
                    .foregroundColor(on ? .white : Theme.muted)
                    .frame(width: on ? 42 : 36, height: on ? 42 : 30)
                    .background(on ? Theme.accent : .clear, in: Circle())
                    .overlay(Circle().stroke(on ? Theme.boardBg : .clear, lineWidth: 4))
                    .offset(y: on ? -13 : 0)
                    .padding(.vertical, on ? -6 : 0)
                Text(label).font(Theme.round(11.5, weight: on ? .semibold : .regular)).tracking(1.6)
                    .foregroundColor(on ? Theme.accent : Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
    }
    /// 问寻栏（寻 10-03 定稿）：没答的一题一张卡，答过的收在下面一张卡里一行一条
    @ViewBuilder private var askSection: some View {
        let qs = ask?.open ?? []
        let done = ask?.answered ?? []
        if !qs.isEmpty {
            SecTitle("问寻", right: "\(qs.count) 个没答")
            ForEach(qs, id: \.key) { q in
                AskCard(q: q, pick: demoPick(q, qs), note: demoPick(q, qs) == nil ? "" : "九月开学后改成跑步了") { a, n in await answer(q.id, a, n) }
            }
        }
        if !done.isEmpty {
            // 答过的：平时折成一行「答过 N 个 ›」，点开才一行一条（寻 10-03 选乙）；字一律宋体淡墨，不加粗
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("答过 \(done.count) 个").font(Theme.cjk(13.5)).foregroundColor(Theme.muted)
                    Spacer(minLength: 0)
                    Text("›").font(Theme.cjk(15)).foregroundColor(Theme.muted)
                        .rotationEffect(.degrees(doneOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { doneOpen.toggle() } }
                if doneOpen {
                    ForEach(Array(done.prefix(30).enumerated()), id: \.element.key) { _, q in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(q.q).font(Theme.cjk(13)).foregroundColor(Theme.text).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            Text(Self.askState(q)).font(Theme.cjk(12)).foregroundColor(Theme.muted).lineLimit(1).fixedSize()
                        }
                        .padding(.top, 9)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
                        .padding(.top, 9)
                    }
                }
            }
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
        }
    }
    /// 截图班 askpick：第一张没答的卡预先选中「不是」并写了补充
    private func demoPick(_ q: AskXun.Q, _ qs: [AskXun.Q]) -> String? {
        (Preview.on && Preview.screen == "askpick" && q.id == qs.first?.id) ? "不是" : nil
    }
    /// 答过的右侧小字：answered/sent 等克批、kept 不用改、done 克已批、rejected 克没采用；不认识的状态当等克批
    static func askState(_ q: AskXun.Q) -> String {
        let s: String
        switch q.status ?? "" {
        case "kept": s = "不用改"
        case "done": s = "克已批"
        case "rejected": s = "克没采用"
        default: s = "等克批"
        }
        return (q.answer ?? "") + " · " + s
    }
    private func loadAsk() async {
        if Preview.on {
            if let d = Preview.json("preview_askxun"), let p = try? JSONDecoder().decode(AskXun.self, from: d) { ask = p }
            return
        }
        guard let token = Keychain.token else { return }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/askxun"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let p = try? JSONDecoder().decode(AskXun.self, from: d) else { return }
        ask = p
    }
    /// 交给克：成功用回包刷新（这张卡挪到「答过的」）；400 答过了 / 404 没这题＝重拉一遍对齐；其余算没交上
    private func answer(_ id: Int, _ a: String, _ note: String) async -> Bool {
        if Preview.on { return false }
        guard let token = Keychain.token else { return false }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/askxun/answer"))
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["id": id, "answer": a]
        if !note.isEmpty { body["note"] = note }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, let p = try? JSONDecoder().decode(AskXun.self, from: d) { ask = p; return true }
        if code == 400 || code == 404 { await loadAsk(); return true }
        return false
    }
    private func fmt(_ n: Int) -> String { NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal) }
    /// 工具卡全文：说明 + 每个参数一行「· 名（必填）：说明」
    private func toolFull(_ t: MemPayload.Tool) -> String {
        var full = t.description ?? ""
        for p in t.params ?? [] { full += "\n\n· " + p.name + (p.required == true ? "（必填）" : "") + ((p.desc?.isEmpty == false) ? "：" + p.desc! : "") }
        return full
    }
    /// 卡面（样式稿 ①）：一样高，衬线卡题＋右边淡墨字数＋›，像思考链那样点开才展开全文
    private func card(_ key: String, title: String, side: String, full: String) -> some View {
        let isOpen = open.contains(key)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.georgiaCJK(16)).tracking(0.16).foregroundColor(Theme.text).lineLimit(1)
                Spacer()
                Text(side).font(Theme.round(11)).tracking(0.44).foregroundColor(Theme.muted)
                Text("›").font(Theme.cjk(13)).foregroundColor(Theme.muted).rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            // 只有抬头这一行开合（寻 10-07：展开后要选正文里的字，点正文别收起）
            .padding(.vertical, 13).contentShape(Rectangle())
            .onTapGesture { if isOpen { open.remove(key) } else { open.insert(key) } }
            if isOpen { RichText(attr: MD.keNS(full, size: 14.2, weight: .regular, lineHeight: 1.65)).padding(.bottom, 13) }
        }
        .padding(EdgeInsets(top: 0, leading: 15, bottom: 0, trailing: 15))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
    }
    private func load() async {
        if Preview.on {
            if let d = Preview.json("preview_mem"), let p = try? JSONDecoder().decode(MemPayload.self, from: d) { data = p } else { failed = true }
            return
        }
        guard let token = Keychain.token else { return }
        if data == nil, let c = NetCache.load("api/memory/injection"), let p = try? JSONDecoder().decode(MemPayload.self, from: c) { data = p }
        var r = URLRequest(url: Gateway.home.appendingPathComponent("api/memory/injection"))
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let p = try? JSONDecoder().decode(MemPayload.self, from: d) else { failed = data == nil; return }
        if NetCache.save("api/memory/injection", d) || data == nil { data = p }
        failed = false
    }
}

/// 问寻卡一张（寻 10-03 定稿）：问句、出处淡字、「是 / 不是」两块淡底钮（不描边）；点中一个才展开补充行与「交给克」
struct AskCard: View {
    let q: AskXun.Q
    var onSend: (String, String) async -> Bool
    @State private var pick: String?
    @State private var note: String
    @State private var focused = false
    @State private var sending = false
    @State private var failed = false
    init(q: AskXun.Q, pick: String? = nil, note: String = "", onSend: @escaping (String, String) async -> Bool) {
        self.q = q
        self.onSend = onSend
        _pick = State(initialValue: pick)
        _note = State(initialValue: note)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(q.q).font(Theme.cjk(15)).lineSpacing(4).foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if let t = q.title, !t.isEmpty {
                Text("整理「\(t)」时想到的").font(Theme.cjk(11.5)).foregroundColor(Theme.muted).lineLimit(1).padding(.top, 6)
            }
            HStack(spacing: 10) { choice("是"); choice("不是") }.padding(.top, 12)
            if pick != nil {
                PlainField(text: $note, focused: $focused, placeholder: "补一句（可不填）", font: Theme.uiSys(13), returnKey: .done, onSubmit: { focused = false })
                    .frame(height: 18)
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(Theme.boardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 10)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if failed { Text("没交上，再点一次").font(Theme.cjk(12)).foregroundColor(Theme.muted) }
                    Button { send() } label: {
                        Text("交给克").font(Theme.cjk(13.5, weight: .medium)).foregroundColor(sending ? Theme.muted : Theme.accent)
                            .padding(.vertical, 2).padding(.leading, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(sending)
                }
                .padding(.top, 10)
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
    }
    /// 淡底圆角块；选中＝淡赤陶底＋朱砂字（夜里跟着变，同敲门那对色）
    private func choice(_ a: String) -> some View {
        let on = pick == a
        return Button { pick = on ? nil : a; failed = false } label: {
            Text(a).font(Theme.cjk(14, weight: on ? .medium : .regular)).foregroundColor(on ? Theme.knockText : Theme.text)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(on ? Theme.knockBg : Theme.boardBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(sending)
    }
    private func send() {
        guard let a = pick, !sending else { return }
        sending = true; failed = false; focused = false
        let n = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        Task {
            let ok = await onSend(a, n)
            sending = false
            if !ok { failed = true }
        }
    }
}
