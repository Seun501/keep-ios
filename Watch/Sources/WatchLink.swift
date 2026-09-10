import Foundation
import Security
import WatchConnectivity
import WatchKit

/// 手机↔手表：手机端 PhoneLink 把登录票放进 applicationContext（启动与登录后各一次），
/// 表这头收下存钥匙串。表上没有登录页，票只从这一条路来；手机退出登录会传空票。
@MainActor
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchLink()
    @Published var hasToken = WatchKeychain.token != nil

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func take(_ ctx: [String: Any]) {
        guard let t = ctx["token"] as? String else { return }
        WatchKeychain.token = t.isEmpty ? nil : t
        hasToken = WatchKeychain.token != nil
        WatchDiag.send("link: token \(hasToken ? "ok" : "cleared")")
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        Task { @MainActor in self.take(ctx) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        Task { @MainActor in self.take(ctx) }
    }
}

/// 口令存钥匙串（同手机端 Keychain，去掉了手机端的诊断依赖）
enum WatchKeychain {
    private static let service = "cn.seunk.keep.watch"
    private static let account = "gateway-token"

    static var token: String? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
            else { return nil }
            return s
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let v = newValue, let data = v.data(using: .utf8) else { return }
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// 盲调试：一句话送到服务器日志（同手机端 PushRegistrar.diag；服务器按 device 名分行）
enum WatchDiag {
    static func send(_ note: String) {
        var req = URLRequest(url: WatchGateway.home.appendingPathComponent("api/push/apns"))
        req.httpMethod = "POST"
        if let t = WatchKeychain.token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["note": note, "device": "Watch·" + WKInterfaceDevice.current().name])
        URLSession.shared.dataTask(with: req).resume()
    }
}

enum WatchGateway {
    static let home = URL(string: "https://ke.seunk.cn/")!
}
