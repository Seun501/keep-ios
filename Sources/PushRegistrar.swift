import UIKit
import UserNotifications

/// 原生推送登记。踩坑册 04 章：
/// - 设备令牌每次启动都上报（重装/恢复/升级都会换）；服务器按 token upsert。
/// - 环境随包来路：Xcode 直装＝sandbox，TestFlight/App Store＝production；一起报给服务器，端点它挑。
/// - 前台也弹横幅（默认前台不显示）。
final class PushRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    static var token: String? { Keychain.token }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Self.registerIfAuthorized()
        return true
    }

    /// 登录成功后、以及每次启动：有权限就注册；没问过就问一次。
    static func registerIfAuthorized() {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
            case .notDetermined:
                c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                    if ok { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
                }
            default:
                break
            }
        }
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.report(token: hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[push] 注册失败：\(error.localizedDescription)")
    }

    private static func report(token hex: String) {
        guard let auth = Self.token else { return }
        var req = URLRequest(url: WebShellController.home.appendingPathComponent("api/push/apns"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["token": hex, "env": Self.environment,
                                      "device": UIDevice.current.name]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("[push] 上报 \(code) \(err?.localizedDescription ?? "")")
        }.resume()
    }

    /// 包来路：有 embedded.mobileprovision 且 aps-environment=development ＝ sandbox；其余按 production。
    /// TestFlight 与 App Store 包的描述文件都是 production。
    private static var environment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .isoLatin1),
           s.contains("<key>aps-environment</key>"),
           let r = s.range(of: "<key>aps-environment</key>") {
            let tail = s[r.upperBound...].prefix(80)
            if tail.contains("development") { return "sandbox" }
        }
        return "production"
        #endif
    }

    // 前台也显示
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
