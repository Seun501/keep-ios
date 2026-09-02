import Foundation

/// 预览模式（打包机模拟器截图用）：KEEP_PREVIEW=1 → 不登录、不联网，正史用包里的假对话（我编的文字，不碰克的正文）。
/// KEEP_SCREEN=chat|drawer|board 决定截哪一页。
enum Preview {
    static var on: Bool { ProcessInfo.processInfo.environment["KEEP_PREVIEW"] == "1" }
    static var screen: String { ProcessInfo.processInfo.environment["KEEP_SCREEN"] ?? "chat" }
    static func json(_ name: String) -> Data? {
        guard let u = Bundle.main.url(forResource: name, withExtension: "json") else { return nil }
        return try? Data(contentsOf: u)
    }
}
