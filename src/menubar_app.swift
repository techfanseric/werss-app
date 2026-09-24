// WERSS菜单栏：常驻状态图标 + 下拉菜单（状态/7天趋势曲线/待办直达/可点击通知）
// 编译: bash bin/build_menubar.sh
// 趋势图样式参考 ai-quota-bar：SwiftUI Path 曲线 + 渐变填充 + NSHostingView 嵌入 NSMenu
import AppKit
import SwiftUI
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

// ---- 7 天历史采样：logs/history.tsv，每行 "unix feeds articles" ----
struct Sample { let t: Date; let feeds: Double; let articles: Double }

enum History {
    static let file = root + "/logs/history.tsv"

    static func load() -> [Sample] {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t")
            guard p.count >= 3, let t = TimeInterval(p[0]), let f = Double(p[1]), let a = Double(p[2]) else { return nil }
            let d = Date(timeIntervalSince1970: t)
            return d >= cutoff ? Sample(t: d, feeds: f, articles: a) : nil
        }.sorted { $0.t < $1.t }
    }

    static func sample(feeds: Double, articles: Double) {
        var lines = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970
        var kept: [String] = []
        for line in lines.split(separator: "\n") {
            if let t = line.split(separator: "\t").first, let v = TimeInterval(t), v >= cutoff { kept.append(String(line)) }
        }
        kept.append("\(Int(Date().timeIntervalSince1970))\t\(Int(feeds))\t\(Int(articles))")
        try? kept.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}

// ---- SwiftUI：7 天趋势图（并排两张小图：订阅 / 文章）----
struct Sparkline: View {
    let name: String
    let color: Color
    let points: [Sample]
    let pick: (Sample) -> Double

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/dd"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let cur = points.last.map(pick) ?? 0
            let first = points.first.map(pick) ?? cur
            let delta = Int(cur - first)
            let deltaText = delta == 0 ? "持平" : (delta > 0 ? "+\(delta)" : "\(delta)")
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6)
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(cur))").font(.system(size: 12, weight: .bold)).monospacedDigit()
                Text("7天\(deltaText)").font(.system(size: 8)).monospacedDigit()
                    .foregroundStyle(delta >= 0 ? Color.green : Color.orange)
            }
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let vals = points.map(pick)
                let lo = (vals.min() ?? 0)
                let hi = max(vals.max() ?? 1, lo + 1)
                let pad = (hi - lo) * 0.15
                let vmin = lo - pad, vmax = hi + pad
                let t1 = Date().timeIntervalSince1970
                let t0 = t1 - 7 * 86400   // 固定 7 天窗口
                func pt(_ s: Sample) -> CGPoint {
                    let x = w * CGFloat((s.t.timeIntervalSince1970 - t0) / (t1 - t0))
                    let y = h - h * CGFloat((pick(s) - vmin) / (vmax - vmin))
                    return CGPoint(x: min(max(0, x), w), y: min(max(2, y), h - 2))
                }
                ZStack {
                    if points.count >= 2 {
                        let line = Path { p in
                            p.move(to: pt(points[0]))
                            for s in points.dropFirst() { p.addLine(to: pt(s)) }
                        }
                        line.stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        Path { p in
                            p.move(to: pt(points[0]))
                            for s in points.dropFirst() { p.addLine(to: pt(s)) }
                            p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                        }.fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    } else {
                        Text("采集中…").font(.system(size: 8)).foregroundStyle(.tertiary)
                            .frame(width: w, height: h, alignment: .center)
                    }
                }
            }
            HStack {
                Text(Self.df.string(from: Date().addingTimeInterval(-7 * 86400))).font(.system(size: 7)).foregroundStyle(.tertiary)
                Spacer()
                Text("今天").font(.system(size: 7)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct TrendPanel: View {
    let samples: [Sample]
    var body: some View {
        HStack(spacing: 14) {
            Sparkline(name: "公众号", color: Color(nsColor: .controlAccentColor), points: samples) { $0.feeds }
                .frame(width: 140, height: 64)
            Sparkline(name: "文章", color: .orange, points: samples) { $0.articles }
                .frame(width: 140, height: 64)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct Status {
    var dict: [String: String] = [:]
    var wereadFail: Bool { dict["weread"] == "FAIL" || dict["weread"] == "LOGINERR" }
    var runnerDown: Bool { dict["runner"] == "DOWN" && sliceLeft > 0 }
    var appDown: Bool { dict["app"] != "OK" || dict["container"] != "UP" }
    var dockerDown: Bool { dict["docker"] == "DOWN" }
    var sliceLeft: Int { Int(dict["slice"] ?? "-1") ?? -1 }
    var level: Int { dockerDown ? 3 : (appDown ? 3 : (wereadFail || runnerDown ? 2 : 1)) }
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
    var lastWereadNag: Date?
    var lastFaultNag: Date?
    var lastSample = Date.distantPast
    var samples: [Sample] = []
    var menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        Notifier.shared.bootstrap()
        samples = History.load()
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
            // 每 5 分钟采样一次趋势数据
            if let f = Double(d["feeds"] ?? ""), f >= 0, Date().timeIntervalSince(self.lastSample) > 300 {
                History.sample(feeds: f, articles: Double(d["articles"] ?? "0") ?? 0)
                self.lastSample = Date()
                self.samples = History.load()
            }
            self.render()
            self.notifyOnTransitions()
        }
    }

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
        if prevWereadFail && !st.wereadFail {
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

        // 7 天趋势（公众号 / 文章双曲线）
        let trendItem = NSMenuItem()
        let hosting = NSHostingView(rootView: TrendPanel(samples: samples))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 84)
        trendItem.view = hosting
        menu.addItem(trendItem)

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
