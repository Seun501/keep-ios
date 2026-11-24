import SwiftUI
import Photos

// MARK: - 「+」面板（11-24 寻定「学小鲸鱼」，克那边和 CC师 页全换）
// 点「+」在输入卡下面展开：上面一排最近的照片（直接勾，勾几张就「添加 n 张」），下面拍照／相册／文件几个大格。
// 读照片要「照片」权限（第一次打开面板时问；只给了部分照片也行，列的就是那部分）。

/// 相册里最近的照片（只读）
@MainActor
final class RecentPhotos: ObservableObject {
    static let shared = RecentPhotos()
    @Published var assets: [PHAsset] = []
    @Published var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private let cache = PHCachingImageManager()

    func load() {
        if Preview.on { return }
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited: fetch()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                Task { @MainActor in
                    self.status = s
                    if s == .authorized || s == .limited { self.fetch() }
                }
            }
        default: break
        }
    }
    private func fetch() {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.fetchLimit = 60
        var a: [PHAsset] = []
        PHAsset.fetchAssets(with: .image, options: o).enumerateObjects { x, _, _ in a.append(x) }
        assets = a
    }
    func thumb(_ a: PHAsset, _ done: @escaping (UIImage?) -> Void) {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic; o.resizeMode = .fast; o.isNetworkAccessAllowed = true
        cache.requestImage(for: a, targetSize: CGSize(width: 260, height: 260), contentMode: .aspectFill, options: o) { img, _ in done(img) }
    }
    /// 勾好的一张变成发出去的那份：原样文件（多为 HEIC）解出图，克那边另带原图与 Live 的视频（同选图器那条路）
    func picked(_ a: PHAsset, live: Bool) async -> PhotoPickerBridge.Picked? {
        let o = PHImageRequestOptions()
        o.isNetworkAccessAllowed = true; o.deliveryMode = .highQualityFormat; o.version = .current
        let got: (Data, String)? = await withCheckedContinuation { c in
            PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { d, uti, _, _ in
                c.resume(returning: d.map { ($0, uti ?? "") })
            }
        }
        guard let (data, uti) = got, let img = UIImage(data: data) else { return nil }
        let ext = uti.contains("heic") ? "heic" : uti.contains("png") ? "png" : "jpg"
        guard live else { return .init(image: img) }
        var video: URL? = nil
        if a.mediaSubtypes.contains(.photoLive), let res = PHAssetResource.assetResources(for: a).first(where: { $0.type == .pairedVideo }) {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).mov")
            let ro = PHAssetResourceRequestOptions(); ro.isNetworkAccessAllowed = true
            let ok: Bool = await withCheckedContinuation { c in
                PHAssetResourceManager.default().writeData(for: res, toFile: out, options: ro) { err in c.resume(returning: err == nil) }
            }
            if ok { video = out }
        }
        return .init(image: img, live: video, orig: (data, ext))
    }
}

struct AttachPanel: View {
    var max: Int                              // 还能加几张
    var live = true                           // 克那边带 Live 视频与原图；CC师 只要静图
    var onCamera: () -> Void
    var onAlbum: () -> Void
    var onFile: (() -> Void)? = nil           // CC师 页才有「文件」
    var onAdd: ([PhotoPickerBridge.Picked]) -> Void
    @ObservedObject private var lib = RecentPhotos.shared
    @State private var sel: [String] = Preview.screen.hasSuffix("plussel") ? ["p1", "p3"] : []   // 勾选顺序（asset 号）
    @State private var adding = false

    var body: some View {
        VStack(spacing: 12) {
            strip
            if sel.isEmpty {
                HStack(spacing: 10) {
                    tile("拍照", "camera", onCamera)
                    tile("相册", "photo.on.rectangle", onAlbum)
                    if let f = onFile { tile("文件", "paperclip", f) }
                }
            } else {
                Button { add() } label: {
                    Text(adding ? "正在取…" : "添加 \(sel.count) 张").font(Theme.round(16, weight: .medium)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain).disabled(adding)
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
        .onAppear { lib.load() }
    }

    @ViewBuilder private var strip: some View {
        if Preview.on {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(0..<9) { i in
                        cell(id: "p\(i)") { RoundedRectangle(cornerRadius: 0).fill(Color(hue: 0.08 + Double(i) * 0.05, saturation: 0.25, brightness: 0.85)) }
                    }
                }
            }
        } else if lib.status == .denied || lib.status == .restricted {
            Button { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } label: {
                Text("到设置里允许 Keep 读照片，这里就能直接勾").font(Theme.round(13)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity).frame(height: 44)
            }.buttonStyle(.plain)
        } else if !lib.assets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(lib.assets, id: \.localIdentifier) { a in
                        cell(id: a.localIdentifier) { AssetThumb(asset: a) }
                    }
                }
            }
            .frame(height: 104)
        }
    }

    private func cell<C: View>(id: String, @ViewBuilder _ content: () -> C) -> some View {
        let n = sel.firstIndex(of: id).map { $0 + 1 }
        return content()
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(n != nil ? Theme.accent : Color.black.opacity(0.28)).frame(width: 24, height: 24)
                    if let n { Text("\(n)").font(Theme.round(13, weight: .semibold)).foregroundColor(.white) }
                    else { Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5).frame(width: 22, height: 22) }
                }
                .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let i = sel.firstIndex(of: id) { sel.remove(at: i) }
                else if sel.count < max { sel.append(id); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }
    }

    private func tile(_ title: String, _ sys: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 6) {
                Image(systemName: sys).font(.system(size: 21, weight: .regular)).foregroundColor(Theme.text)
                Text(title).font(Theme.round(14)).foregroundColor(Theme.text)
            }
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add() {
        let ids = sel
        let byID = Dictionary(uniqueKeysWithValues: lib.assets.map { ($0.localIdentifier, $0) })
        adding = true
        Task {
            var out: [PhotoPickerBridge.Picked] = []
            for id in ids { if let a = byID[id], let p = await lib.picked(a, live: live) { out.append(p) } }
            adding = false; sel = []
            onAdd(out)
        }
    }
}

private struct AssetThumb: View {
    let asset: PHAsset
    @State private var img: UIImage? = nil
    var body: some View {
        ZStack {
            Theme.userBubble
            if let img { Image(uiImage: img).resizable().scaledToFill() }
        }
        .onAppear { if img == nil { RecentPhotos.shared.thumb(asset) { img = $0 } } }
    }
}
