import Foundation

/// 网关地址。放在 actor 之外，登录/推送/壳三处都能随手取。
enum Gateway {
    static let home = URL(string: "https://ke.seunk.cn/")!
}
