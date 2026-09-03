import Foundation

/// 上次拉到的东西落盘（Application Support/keep-cache）：冷启动先亮上次的内容再去网上刷。
/// 09-03 寻验：闲置两小时后头一次开，出站通道卡了四十来秒，整页白着——网页版也白，App 不该白。
enum DiskCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("keep-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func read(_ name: String) -> Data? {
        if Preview.on { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func write(_ name: String, _ data: Data) {
        if Preview.on { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// 退出登录时清空（别把上一个口令拉下来的正史留给下一个人看）
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for k in ["cache.usage", "cache.days"] { UserDefaults.standard.removeObject(forKey: k) }
    }
}
