// WERSS菜单栏：常驻状态图标 + 下拉菜单 + 可点击系统通知（点击直达动作）
// 编译: bash bin/build_menubar.sh（swiftc → WERSS菜单栏.app/Contents/MacOS/main）
import AppKit
import UserNotifications

let rootURL = Bundle.main.bundleURL.deletingLastPathComponent()  // .app 的上级 = werss-app 根
let root = rootURL.path

func shEnv() -> [String: String] {
    var e = ProcessInfo.processInfo.environment
    let home = e["HOME"] ?? NSHomeDirectory()
    e["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home)/.local/bin:" + (e["PATH"] ?? "")
    e["LANG"] = "en_US.UTF-8"
    e["LC_ALL"] = "en_US.UTF-8"
    e["HOME"] = home
    return e
}

func runSh(_ cmd: String) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        p.environment = shEnv()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

func runShCapture(_ cmd: String, timeout: Double, done: @escaping (String) -> Void) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        p.environment = shEnv()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { DispatchQueue.main.async { done("") }; return }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        DispatchQueue.main.async { done(out) }
    }
}

struct Status {
    var dict: [String: String] = [:]
    var wereadFail: Bool { dict["weread"] == "FAIL" || dict["weread"] == "LOGINERR" }
    var runnerDown: Bool { dict["runner"] == "DOWN" && sliceLeft > 0 }
    var appDown: Bool { dict["app"] != "OK" || dict["container"] != "UP" }
    var dockerDown: Bool { dict["docker"] == "DOWN" }
    var sliceLeft: Int { Int(dict["slice"] ?? "-1") ?? -1 }
    var level: Int { dockerDown ? 3 : (appDown ? 3 : (wereadFail || runnerDown ? 2 : 1)) }  // 1正常 2待办 3故障
}

// ---- 可点击通知：真 App 进程 + 事件循环，权限/点击回调均可用 ----
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var authorized = false

    func bootstrap() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    // 发通知（同 id 自动替换旧的，不堆积）；action = 点击后执行的动作
    func post(id: String, title: String, body: String, action: String, sound: Bool = true) {
        guard authorized else { return }
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [id])
        c.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["action": action]
        if sound { content.sound = .default }
        c.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.notification.request.content.userInfo["action"] as? String ?? "admin"
        switch action {
        case "scan":   runSh("bash '\(root)/bin/open_scan_page.sh'")
        case "repair": runSh("bash '\(root)/bin/keepalive.sh'")
        default:       runSh("open http://localhost:8001/")
        }
        completionHandler()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var st = Status()
    var lastLevel = 0
    var prevWereadFail = false
    var lastWereadNag: Date?          // 待扫码重复提醒节流（30 分钟）
    var lastFaultNag: Date?
    var menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        Notifier.shared.bootstrap()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "werss …"
        statusItem.button?.toolTip = "微信公众号采集系统"
        rebuildMenu()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        runShCapture("bash '\(root)/bin/status.sh' --parse", timeout: 60) { [weak self] out in
            guard let self = self else { return }
            var d: [String: String] = [:]
            for line in out.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { d[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
            }
            self.prevWereadFail = self.st.wereadFail
            self.lastLevel = self.st.level
            self.st = Status()
            self.st.dict = d
            self.render()
            self.notifyOnTransitions()
        }
    }

    // 状态变化 → 可点击通知（点击直达对应动作）；重复待办 30 分钟节流
    func notifyOnTransitions() {
        let now = Date()
        if st.wereadFail && (!prevWereadFail || lastWereadNag == nil || now.timeIntervalSince(lastWereadNag!) > 1800) {
            Notifier.shared.post(id: "werss-weread",
                title: "微信读书授权失效，待扫码",
                body: "点此直达扫码页（自动登录）。文章正文暂停中，扫码后 ≤10 分钟自动恢复采集",
                action: "scan")
            lastWereadNag = now
        }
        if st.level == 3 && (lastLevel < 3 || lastFaultNag == nil || now.timeIntervalSince(lastFaultNag!) > 1800) {
            Notifier.shared.post(id: "werss-fault",
                title: "werss 系统故障",
                body: "Docker/容器/应用异常。点此立即自动修复",
                action: "repair")
            lastFaultNag = now
        }
        if !prevWereadFail && st.wereadFail == false && lastLevel >= 2 {
            // 扫码成功 → 提示已自动恢复
            Notifier.shared.post(id: "werss-recovered",
                title: "微信读书授权已恢复",
                body: "文章正文采集将自动继续（≤10 分钟内下一轮补抓生效）",
                action: "admin", sound: false)
        }
        if lastLevel >= 2 && st.level == 1 {
            Notifier.shared.post(id: "werss-recovered",
                title: "werss 已恢复正常",
                body: "全部组件在线，采集运行中",
                action: "admin", sound: false)
        }
    }

    func render() {
        switch st.level {
        case 3: statusItem.button?.title = "werss ✕"
        case 2: statusItem.button?.title = "werss ⚠️"
        default: statusItem.button?.title = "werss ✓"
        }
        let d = st.dict
        statusItem.button?.toolTip = "订阅\(d["feeds"] ?? "?") 文章\(d["articles"] ?? "?") 待采\(d["slice"] ?? "?")"
        rebuildMenu()
    }

    func mkItem(_ title: String, action: Selector? = nil, bold: Bool = false) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = action == nil ? nil : self
        m.isEnabled = action != nil
        if bold { m.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        return m
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let d = st.dict
        menu.addItem(mkItem("Docker: \(d["docker"] ?? "?")   容器: \(d["container"] ?? "?")   应用: \(d["app"] ?? "?")"))
        menu.addItem(mkItem("采集 runner: \(d["runner"] ?? "?")   待采队列: \(d["slice"] ?? "?") 家"))
        menu.addItem(mkItem("订阅: \(d["feeds"] ?? "?")   文章: \(d["articles"] ?? "?")（有正文 \(d["has_content"] ?? "?")）"))
        menu.addItem(mkItem("微信读书授权: \(d["weread"] == "OK" ? "正常" : (d["weread"] == "FAIL" ? "已失效，待扫码" : (d["weread"] ?? "?")) )"))

        if st.wereadFail || st.runnerDown || st.appDown || st.dockerDown {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(mkItem("── 待办（点击直达）──"))
            if st.wereadFail { menu.addItem(mkItem("→ 微信读书待扫码：直达扫码页", action: #selector(openScan), bold: true)) }
            if st.appDown || st.dockerDown { menu.addItem(mkItem("→ 系统故障：立即保活修复", action: #selector(runKeepalive), bold: true)) }
            else if st.runnerDown { menu.addItem(mkItem("→ runner 未运行：拉起", action: #selector(runKeepalive), bold: true)) }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("打开管理页", action: #selector(openAdmin)))
        menu.addItem(mkItem("直达扫码页（自动登录）", action: #selector(openScan)))
        menu.addItem(mkItem("立即保活检查", action: #selector(runKeepalive)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("交接导出（打备份包）", action: #selector(doExport)))
        menu.addItem(mkItem("交接导入（选备份包）", action: #selector(doImport)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("刷新状态", action: #selector(refreshNow)))
        menu.addItem(mkItem("退出菜单栏", action: #selector(quit)))
        statusItem.menu = menu
    }

    @objc func refreshNow() { statusItem.button?.title = "werss …"; refresh() }
    @objc func openAdmin() { runSh("open http://localhost:8001/") }
    @objc func openScan() { runSh("bash '\(root)/bin/open_scan_page.sh'") }
    @objc func runKeepalive() { runSh("bash '\(root)/bin/keepalive.sh'") }
    @objc func doExport() { NSWorkspace.shared.open(rootURL.appendingPathComponent("交接导出.command")) }
    @objc func doImport() { NSWorkspace.shared.open(rootURL.appendingPathComponent("交接导入.command")) }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
