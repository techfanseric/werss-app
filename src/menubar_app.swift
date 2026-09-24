// WERSS菜单栏：常驻状态图标 + 下拉菜单（状态/7天趋势曲线/待办直达/可点击通知）
// 编译: bash bin/build_menubar.sh
// 趋势图样式参考 ai-quota-bar：SwiftUI Path 曲线 + 渐变填充 + NSHostingView 嵌入 NSMenu
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

// ---- 7 天历史采样：logs/history.tsv，每行 "unix feeds articles" ----
struct Sample { let t: Date; let feeds: Double; let articles: Double; let hc: Double? }

enum History {
    static let file = root + "/logs/history.tsv"

    static func load() -> [Sample] {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t")
            guard p.count >= 3, let t = TimeInterval(p[0]), let f = Double(p[1]), let a = Double(p[2]) else { return nil }
            let hc = p.count >= 4 ? Double(p[3]) : nil
            let d = Date(timeIntervalSince1970: t)
            return d >= cutoff ? Sample(t: d, feeds: f, articles: a, hc: hc) : nil
        }.sorted { $0.t < $1.t }
    }

    static func sample(feeds: Double, articles: Double, hc: Double?) {
        var lines = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-8 * 86400).timeIntervalSince1970
        var kept: [String] = []
        for line in lines.split(separator: "\n") {
            if let t = line.split(separator: "\t").first, let v = TimeInterval(t), v >= cutoff { kept.append(String(line)) }
        }
        var row = "\(Int(Date().timeIntervalSince1970))\t\(Int(feeds))\t\(Int(articles))"
        if let hc = hc { row += "\t\(Int(hc))" }
        kept.append(row)
        try? kept.joined(separator: "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}

// ---- 7 天趋势图（纯 AppKit 自绘，上下两行：公众号 / 文章，各自占满整行宽）----
final class TrendView: NSView {
    var samples: [Sample] = [] { didSet { needsDisplay = true } }
    var articlesSub = "" { didSet { needsDisplay = true } }   // 如 "正文 790"
    override var intrinsicContentSize: NSSize { NSSize(width: 340, height: 190) }

    private func drawSeries(_ rect: NSRect, name: String, color: NSColor, values: [Double], sub: String?, axisBottom: Bool) {
        // rect 结构：[头行 15][空 4][曲线区][底 8]
        let cur = values.last ?? 0
        let first = values.first ?? cur
        let delta = Int(cur - first)
        let deltaText = delta == 0 ? "持平" : (delta > 0 ? "+\(delta)" : "\(delta)")
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byClipping

        // 头行：色点 名称 [副信息] …… 当前值 7天增量（右对齐组合串，防叠字）
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - 9, width: 6, height: 6), xRadius: 2, yRadius: 2).fill()
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        (name as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.maxY - 12), withAttributes: nameAttrs)
        if let sub = sub, !sub.isEmpty {
            let nx = rect.minX + 10 + (name as NSString).size(withAttributes: nameAttrs).width + 6
            (sub as NSString).draw(at: NSPoint(x: nx, y: rect.maxY - 12),
                withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        let head = NSMutableAttributedString()
        head.append(NSAttributedString(string: "\(Int(cur))", attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        head.append(NSAttributedString(string: "  7天\(deltaText)", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: delta >= 0 ? NSColor.systemGreen : NSColor.systemOrange]))
        head.draw(at: NSPoint(x: rect.maxX - head.size().width - 2, y: rect.maxY - 13))

        // 曲线区
        let chart = NSRect(x: rect.minX, y: rect.minY + (axisBottom ? 10 : 5), width: rect.width, height: rect.height - 24)
        guard values.count >= 2 else {
            ("采集中…" as NSString).draw(in: chart, withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor])
            return
        }
        let lo = values.min()!, hi = max(values.max()!, lo + 1)
        let pad = (hi - lo) * 0.18
        let vmin = lo - pad, vmax = hi + pad
        let t1 = Date().timeIntervalSince1970
        let t0 = t1 - 7 * 86400   // 固定 7 天窗口
        func pt(_ i: Int) -> NSPoint {
            let x = chart.minX + chart.width * CGFloat(max(0, min(1, (samples[i].t.timeIntervalSince1970 - t0) / (t1 - t0))))
            let y = chart.minY + chart.height * CGFloat(max(0.02, min(0.98, (values[i] - vmin) / (vmax - vmin))))
            return NSPoint(x: x, y: y)
        }
        let line = NSBezierPath()
        line.move(to: pt(0))
        for i in 1..<values.count { line.line(to: pt(i)) }
        line.lineWidth = 1.5; line.lineJoinStyle = .round
        color.setStroke(); line.stroke()
        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: chart.maxX, y: chart.minY))
        area.line(to: NSPoint(x: chart.minX, y: chart.minY))
        area.close()
        NSGradient(starting: color.withAlphaComponent(0.30), ending: color.withAlphaComponent(0.02))?
            .draw(in: area, angle: -90)
    }

    override func draw(_ dirtyRect: NSRect) {
        let feeds = samples.map { $0.feeds }
        let articles = samples.map { $0.articles }
        let inner = NSRect(x: bounds.minX + 14, y: bounds.minY + 6, width: bounds.width - 28, height: bounds.height - 14)
        let rowH = (inner.height - 16) / 2   // 16 = 两行之间的间隔
        drawSeries(NSRect(x: inner.minX, y: inner.minY + rowH + 16, width: inner.width, height: rowH),
                   name: "公众号", color: .controlAccentColor, values: feeds, sub: nil, axisBottom: false)
        drawSeries(NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: rowH),
                   name: "文章", color: .systemOrange, values: articles, sub: articlesSub.isEmpty ? nil : articlesSub, axisBottom: true)
        // 底部时间轴（整图一条）
        let f = DateFormatter(); f.dateFormat = "MM/dd"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: NSColor.tertiaryLabelColor]
        (f.string(from: Date().addingTimeInterval(-7 * 86400)) as NSString)
            .draw(at: NSPoint(x: inner.minX, y: inner.minY + 1), withAttributes: attrs)
        ("今天" as NSString).draw(at: NSPoint(x: inner.maxX - 24, y: inner.minY + 1), withAttributes: attrs)
    }
}

// 状态行：左侧文字 + 右侧刷新图标按钮（点击即重新拉取状态）
final class StatusRowView: NSView {
    var onRefresh: (() -> Void)?
    private let label: NSTextField
    private let button: NSButton

    init(text: String) {
        label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        let icon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage()
        button = NSButton(image: icon, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "刷新状态"
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 18))
        addSubview(label)
        addSubview(button)
        button.target = self
        button.action = #selector(clickRefresh)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 0, y: (frame.height - label.frame.height) / 2)
        button.frame.size = NSSize(width: 18, height: 16)
        button.frame.origin = NSPoint(x: frame.width - 20, y: (frame.height - 16) / 2)
    }

    @objc private func clickRefresh() {
        button.contentTintColor = .controlAccentColor
        onRefresh?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.button.contentTintColor = .secondaryLabelColor
        }
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
                History.sample(feeds: f, articles: Double(d["articles"] ?? "0") ?? 0, hc: Double(d["has_content"] ?? "") ?? nil)
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
        if bold { m.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]) }
        return m
    }

    func rebuildMenu() {
        menu.removeAllItems()
        menu.font = NSFont.systemFont(ofSize: 12)
        let d = st.dict
        // 行1 组件健康（右侧内嵌刷新图标按钮）
        let row1 = StatusRowView(text: "Docker \(d["docker"] ?? "?") · 容器 \(d["container"] ?? "?") · 应用 \(d["app"] ?? "?") · ego \(d["ego"] ?? "?")")
        row1.onRefresh = { [weak self] in self?.refreshNow() }
        row1.frame = NSRect(x: 0, y: 0, width: 340, height: 18)
        let row1Item = NSMenuItem()
        row1Item.view = row1
        menu.addItem(row1Item)
        menu.addItem(mkItem("runner \(d["runner"] ?? "?") · 待采 \(d["slice"] ?? "?") 家 · 磁盘 \(d["disk_gb"] ?? "?")G · 备份 \(d["backup_days"] ?? "?")天前"))
        // 订阅/文章当前值由趋势图头行展示，不再重复列文字行
        menu.addItem(mkItem("微信读书授权 \(d["weread"] == "OK" ? "正常" : (d["weread"] == "FAIL" ? "失效待扫码" : (d["weread"] ?? "?"))) · 限流 \(d["throttled"] == "yes" ? "冷却中" : "无")"))

        // 7 天趋势（公众号 / 文章双曲线）
        let trendItem = NSMenuItem()
        let trend = TrendView(frame: NSRect(x: 0, y: 0, width: 340, height: 190))
        trend.samples = samples
        trend.articlesSub = d["has_content"].flatMap { Int($0).map { "正文 \($0)" } } ?? ""
        trendItem.view = trend
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
