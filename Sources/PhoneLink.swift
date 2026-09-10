import Foundation
import WatchConnectivity

/// 手机→手表：把登录票放进 applicationContext（启动与登录/退出后各一次），表那头 WatchLink 收下。
/// applicationContext 只留最新一份、表不在线时系统攒着下次送——正合适传票。没配对手表就什么都不做。
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 票变了就传（登录/退出都走这里；启动时激活完也会传一次）
    func sendToken() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        do {
            try WCSession.default.updateApplicationContext(["token": Keychain.token ?? "", "at": Date().timeIntervalSince1970])
        } catch {
            PushRegistrar.diag("link: context failed \(error.localizedDescription)")
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        PushRegistrar.diag("link: activated=\(state.rawValue) paired=\(session.isPaired) watchApp=\(session.isWatchAppInstalled)")
        sendToken()
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) { sendToken() }   // 她刚装上手表端＝这一刻传票
}
