import SwiftUI
import WatchKit

/// Keep 手表端（09-10 寻定）。第一期＝腕上健康中继：表自己读健康库、自己推给网关——
/// 昨天档不等她解锁手机，白天隔一阵一份快照。登录票由手机端经 WatchConnectivity 传来，表上不登录。
@main
struct KeepWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    var body: some Scene { WindowGroup { WatchHome() } }
}

final class WatchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchLink.shared.activate()
        WatchHealth.shared.scheduleRefresh()
    }

    func applicationDidBecomeActive() {
        Task { await WatchHealth.shared.sync(reason: "active") }
    }

    /// 后台刷新（06:50 起每小时一班到中午，之后每小时一份快照）：读一遍、推一遍、再约下一班
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let t = task as? WKApplicationRefreshBackgroundTask {
                Task {
                    await WatchHealth.shared.sync(reason: "refresh")
                    WatchHealth.shared.scheduleRefresh()
                    t.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

/// 表盘上的 Keep 页：只报状态，没有别的。淡水色底＋同系深字（寻的口味）。
struct WatchHome: View {
    @ObservedObject private var h = WatchHealth.shared
    @ObservedObject private var link = WatchLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keep").font(.system(size: 20, weight: .semibold, design: .serif))
            Text(link.hasToken ? h.status : "等手机把登录票传过来（打开手机上的 Keep）")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("现在同步") { Task { await h.sync(reason: "tap", force: true) } }
                .font(.footnote)
        }
        .padding(.horizontal, 6)
    }
}
