import SwiftUI
import Photos

// MARK: - 「+」面板（11-24 寻定「学小鲸鱼」，克那边和 CC师 页全换）
// 点「+」在输入卡下面展开：上面一排最近的照片（勾一张就进输入框，再点或在输入框里点 × 就撤），下面拍照／相册／文件几个大格。
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

extension Animation {
    /// 「+」面板开合、输入框里添图都用键盘那条曲线（11-27 寻：开面板时输入框先冲过头再回、收键盘和起面板各走各的，看着跳）
    static let plusPanel = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
}

struct AttachPanel: View {
    var max: Int                              // 还能加几张
    var live = true                           // 克那边带 Live 视频与原图；CC师 只要静图
    var selected: [String]                    // 已经进了输入框的那几张（asset 号；输入框里点 × 删掉，这边的勾跟着消失）
    var onCamera: () -> Void
    var onAlbum: () -> Void
    var onFile: (() -> Void)? = nil           // CC师 页才有「文件」
    var onPick: (String, PhotoPickerBridge.Picked) -> Void
    var onUnpick: (String) -> Void
    @ObservedObject private var lib = RecentPhotos.shared
    @State private var loading: Set<String> = []                                              // 勾了还在取原图的
    @State private var demo: Set<String> = Preview.screen.hasSuffix("plussel") ? ["p0", "p1"] : []   // 截图班的假勾

    var body: some View {
        VStack(spacing: 12) {
            strip
            HStack(spacing: 10) {
                tile("拍照", "att-camera", onCamera)   // Lucide 细线（11-24 寻：系统图标开了粗体文本太粗）
                tile("相册", "att-image", onAlbum)
                if let f = onFile { tile("文件", "att-clip", f) }
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
                        cell(id: "p\(i)", asset: nil) { RoundedRectangle(cornerRadius: 0).fill(Color(hue: 0.08 + Double(i) * 0.05, saturation: 0.25, brightness: 0.85)) }
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
                        cell(id: a.localIdentifier, asset: a) { AssetThumb(asset: a) }
                    }
                }
            }
            .frame(height: 104)
        } else {
            Color.clear.frame(height: 104)   // 照片还没读出来先占住这排的高（11-27 寻：第一次打开面板读完照片再长高一截，输入框又跳一下）
        }
    }

    private func cell<C: View>(id: String, asset: PHAsset?, @ViewBuilder _ content: () -> C) -> some View {
        let on = selected.contains(id) || loading.contains(id) || demo.contains(id)
        return content()
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(on ? Theme.accent : Color.black.opacity(0.28)).frame(width: 24, height: 24)
                    if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white) }
                    else { Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5).frame(width: 22, height: 22) }
                }
                .padding(6)
            }
            .opacity(loading.contains(id) ? 0.6 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if Preview.on { if demo.contains(id) { demo.remove(id) } else { demo.insert(id) }; return }
                if selected.contains(id) { onUnpick(id); return }
                guard let a = asset, !loading.contains(id), max - loading.count > 0 else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                loading.insert(id)
                Task {
                    let p = await lib.picked(a, live: live)
                    loading.remove(id)
                    if let p { onPick(id, p) }
                }
            }
    }

    private func tile(_ title: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 6) {
                Image(icon).renderingMode(.template).resizable().frame(width: 23, height: 23).foregroundColor(Theme.text)
                Text(title).font(Theme.round(14)).foregroundColor(Theme.text)
            }
            .frame(maxWidth: .infinity).frame(height: 76)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
