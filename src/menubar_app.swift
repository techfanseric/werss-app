// WERSS菜单栏：常驻状态图标 + 下拉菜单（状态/14天趋势曲线/待办直达/可点击通知）
// 编译: bash bin/build_menubar.sh（与 src/review_ui.swift 一起编译——审核窗口/进程助手在那边）
// 趋势图样式参考 ai-quota-bar：SwiftUI Path 曲线 + 渐变填充 + NSHostingView 嵌入 NSMenu
import AppKit
import UserNotifications

// ---- 14 天历史采样：logs/history.tsv，每行 "unix feeds articles" ----
struct Sample { let t: Date; let feeds: Double; let articles: Double; let hc: Double? }

enum History {
    static let file = root + "/logs/history.tsv"

    static func load() -> [Sample] {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        let cutoff = Date().addingTimeInterval(-15 * 86400)   // 14 天柱状图 + 1 天缓冲
        return s.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t")
            guard p.count >= 3, let t = TimeInterval(p[0]), let f = Double(p[1]), let a = Double(p[2]) else { return nil }
            let hc = p.count >= 4 ? Double(p[3]) : nil
            let d = Date(timeIntervalSince1970: t)
            return d >= cutoff ? Sample(t: d, feeds: f, articles: a, hc: hc) : nil
        }.sorted { $0.t < $1.t }
    }

    static func sample(feeds: Double, articles: Double, hc: Double?) {
        let lines = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        let cutoff = Date().addingTimeInterval(-16 * 86400).timeIntervalSince1970
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

// ---- 14 天趋势图（纯 AppKit 自绘；三列：左饼图（公众号进度 csv_added/pending/notfound）+ 右上公众号曲线 + 右下文章曲线）----
final class TrendView: NSView {
    var samples: [Sample] = [] { didSet { needsDisplay = true } }
    var articlesSub = "" { didSet { needsDisplay = true } }   // 如 "正文 790"
    // 实时 feeds / articles（来自 status.sh），跨过午夜 history 还没今天采样时兜底
    var liveFeeds: Double = -1 { didSet { needsDisplay = true } }
    var liveArticles: Double = -1 { didSet { needsDisplay = true } }
    // 饼图数据源（公众号进度：已采/待采/未找到，任一 < 0 表示数据无效）
    var pieAdded: Double = -1 { didSet { needsDisplay = true } }
    var piePending: Double = -1 { didSet { needsDisplay = true } }
    var pieNotfound: Double = -1 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: 340, height: 150) }

    // 7 天 × 24 小时柱状图：168 根柱子（每天一组 24 根），高度 = 该小时增量；x 轴每天显示一次日期；组间用浅色分隔线
    // liveValue（status.sh 实时 feeds/articles）覆盖今天当前小时 lastValue 并重算 delta
    private func drawBars(_ rect: NSRect, name: String, color: NSColor, samples: [Sample], value: (Sample) -> Double, sub: String?, axisBottom: Bool, liveValue: Double = -1) {
        // rect 结构：[头行 13][曲线区][底 12]
        var daily = dailyBars(samples, value: value)            // 168 项（7×24）

        // 用 status.sh 实时值覆盖今天当前小时（索引 6*24+currentHour）
        if liveValue >= 0 {
            let cal = Calendar.current
            let currentHour = cal.component(.hour, from: Date())
            let idx = 6 * 24 + currentHour
            if idx < daily.count {
                let prevHourVal: Double = idx > 0 ? daily[idx - 1].lastValue : 0
                let hourDelta = max(0, liveValue - prevHourVal)
                daily[idx] = (day: daily[idx].day, lastValue: liveValue, delta: hourDelta)
            }
        }

        let lastValue = daily.last?.lastValue ?? 0

        // 头行：色点 名称 [副信息] …… 当前值
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - 8, width: 4, height: 4), xRadius: 1.5, yRadius: 1.5).fill()
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        (name as NSString).draw(at: NSPoint(x: rect.minX + 10, y: rect.maxY - 12), withAttributes: nameAttrs)
        if let sub = sub, !sub.isEmpty {
            let nx = rect.minX + 10 + (name as NSString).size(withAttributes: nameAttrs).width + 6
            (sub as NSString).draw(at: NSPoint(x: nx, y: rect.maxY - 12),
                withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        let head = NSMutableAttributedString()
        head.append(NSAttributedString(string: "\(Int(lastValue))", attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        head.draw(at: NSPoint(x: rect.maxX - head.size().width - 2, y: rect.maxY - 13))

        // 柱状区
        let chart = NSRect(x: rect.minX, y: rect.minY + (axisBottom ? 12 : 5), width: rect.width, height: rect.height - 24)
        let maxDelta = max(daily.map { $0.delta }.max() ?? 0, 1)
        let barCount = 168
        let gap: CGFloat = 0
        let barW = chart.width / CGFloat(barCount)   // 每根柱子 ~1.2px，无间隙（barcode 风格）
        let baseY = chart.minY

        // 柱子：delta>0 画细彩色矩形；delta=0 画明显浅色 baseline（让 24 个小时位置都肉眼可见）
        for (i, item) in daily.enumerated() {
            let x = chart.minX + CGFloat(i) * barW
            NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: max(0.5, barW - 0.1), height: 1.5), xRadius: 0.3, yRadius: 0.3).fill()
            if item.delta > 0 {
                let h = CGFloat(item.delta / maxDelta) * chart.height
                let barH = max(1.5, h)
                let bar = NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: max(0.5, barW - 0.1), height: barH), xRadius: 0.3, yRadius: 0.3)
                color.setFill()
                bar.fill()
            }
        }

        // 每天总增量（7 个数字，画在每天组内最高柱子的顶上方居中）
        let dayTotalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        for d in 0..<7 {
            let dayTotal: Double = (0..<24).reduce(0.0) { $0 + max(0, daily[d*24 + $1].delta) }
            guard dayTotal > 0 else { continue }
            let maxH: CGFloat = (0..<24).map { CGFloat(daily[d*24 + $0].delta / maxDelta) * chart.height }.max() ?? 0
            let i = d * 24 + 12   // x 位置：每天中午 12 点（组内居中）
            let x = chart.minX + CGFloat(i) * barW + barW / 2
            let txt = "\(Int(dayTotal))" as NSString
            let size = txt.size(withAttributes: dayTotalAttrs)
            let lx = min(max(chart.minX, x - size.width / 2), chart.maxX - size.width)
            txt.draw(at: NSPoint(x: lx, y: baseY + max(1.0, maxH) + 1), withAttributes: dayTotalAttrs)
        }

        // 组间分隔线：每天末尾只画底部 6px 短刻度（避免看起来像柱子）；颜色更淡
        NSColor.tertiaryLabelColor.withAlphaComponent(0.18).setStroke()
        for d in 1..<7 {
            let x = chart.minX + CGFloat(d * 24) * barW - gap / 2
            let sep = NSBezierPath()
            sep.move(to: NSPoint(x: x, y: baseY - 1))
            sep.line(to: NSPoint(x: x, y: baseY - 7))   // 仅底部 6px
            sep.lineWidth = 0.5
            sep.stroke()
        }

        // x 轴日期：每天中午（i = d*24 + 12）画一个日期标签，7 个标签
        if axisBottom {
            let lAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let df = DateFormatter(); df.dateFormat = "d"
            for d in 0..<7 {
                let i = d * 24 + 12   // 每天的中午 12 点
                guard i < daily.count else { continue }
                let item = daily[i]
                let txt = df.string(from: item.day) as NSString
                let x = chart.minX + CGFloat(i) * barW + barW / 2
                let size = txt.size(withAttributes: lAttrs)
                let lx = min(max(chart.minX, x - size.width / 2), chart.maxX - size.width)
                txt.draw(at: NSPoint(x: lx, y: rect.minY + 1), withAttributes: lAttrs)
            }
        }
    }

    // 按小时分桶：最近 7 天 × 24 小时 = 168 项（day 0..6，day 6 = 今天）；每项代表那一个小时
    // delta = max(0, lastValue - 前一小时 lastValue)；第一项 delta=0（基线）
    // 缺失小时 delta=0（lastVal 沿用 prevVal）；未来小时 lastVal=0 delta=0
    private func dailyBars(_ samples: [Sample], value: (Sample) -> Double) -> [(day: Date, lastValue: Double, delta: Double)] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let currentHour = cal.component(.hour, from: now)  // 0..23

        // byHour[hour] = 该小时最后一个采样值（只统计 7 天内的）
        var byHour: [Date: Double] = [:]
        for s in samples {
            let day = cal.startOfDay(for: s.t)
            let dayDiff = cal.dateComponents([.day], from: day, to: today).day ?? 99
            guard dayDiff >= 0 && dayDiff < 7 else { continue }
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: s.t)
            if let h = cal.date(from: comps) {
                byHour[h] = value(s)
            }
        }

        var result: [(Date, Double, Double)] = []
        var prevVal = 0.0
        for d in 0..<7 {
            let day = cal.date(byAdding: .day, value: -(6 - d), to: today)!
            for h in 0..<24 {
                let hour = cal.date(byAdding: .hour, value: h, to: day)!
                let isFuture = (d == 6 && h > currentHour)
                let lastVal: Double
                let delta: Double
                if isFuture {
                    lastVal = 0
                    delta = 0
                } else if let v = byHour[hour] {
                    lastVal = v
                    delta = (d == 0 && h == 0) ? 0 : max(0, v - prevVal)
                } else {
                    // 该小时没采样：lastVal 沿用 prevVal（保持连续），delta = 0
                    lastVal = prevVal
                    delta = 0
                }
                result.append((hour, lastVal, delta))
                prevVal = lastVal
            }
        }
        return result.map { (day: $0.0, lastValue: $0.1, delta: $0.2) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inner = NSRect(x: bounds.minX + 14, y: bounds.minY + 6, width: bounds.width - 28, height: bounds.height - 14)
        // 三列布局：左饼图（~1/3 宽）+ 间隔 + 右上公众号柱状图 + 右下文章柱状图
        let pieW: CGFloat = 96
        let gap: CGFloat = 14
        let trendX = inner.minX + pieW + gap
        let trendW = inner.maxX - trendX
        // 左列：饼图 + 图例 + 总数（垂直排列）
        drawPieChart(in: NSRect(x: inner.minX, y: inner.minY, width: pieW, height: inner.height))
        // 右两行：公众号 + 文章 14 天柱状图（与饼图同高度）
        let rowH = (inner.height - 16) / 2
        drawBars(NSRect(x: trendX, y: inner.minY + rowH + 16, width: trendW, height: rowH),
                 name: "公众号", color: .controlAccentColor, samples: samples, value: { $0.feeds }, sub: nil, axisBottom: false, liveValue: liveFeeds)
        drawBars(NSRect(x: trendX, y: inner.minY, width: trendW, height: rowH),
                 name: "文章", color: .systemOrange, samples: samples, value: { $0.articles }, sub: articlesSub.isEmpty ? nil : articlesSub, axisBottom: true, liveValue: liveArticles)
    }

    // 左列饼图：饼图（56px 直径，居顶）+ 3 行图例（已采/待采/未找到）+ 总数
    private func drawPieChart(in rect: NSRect) {
        let pieValid = pieAdded >= 0 && piePending >= 0 && pieNotfound >= 0 && (pieAdded + piePending + pieNotfound) > 0
        let dia: CGFloat = 56
        let pieTopY = rect.maxY - dia - 6    // 距顶 6px
        let pieRect = NSRect(x: rect.midX - dia / 2, y: pieTopY, width: dia, height: dia)
        let cx = pieRect.midX, cy = pieRect.midY, r = dia / 2

        // 扇形
        if pieValid {
            let total = pieAdded + piePending + pieNotfound
            let slices: [(Double, NSColor)] = [
                (pieAdded, NSColor.systemGreen),
                (piePending, NSColor.controlAccentColor),
                (pieNotfound, NSColor.systemGray),
            ]
            var startDeg = -90.0
            for (val, color) in slices where val > 0 {
                let sweep = 360.0 * val / total
                let endDeg = startDeg - sweep
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx, y: cy))
                p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r,
                    startAngle: CGFloat(startDeg), endAngle: CGFloat(endDeg), clockwise: true)
                p.close()
                color.setFill()
                p.fill()
                startDeg = endDeg
            }
            NSColor.windowBackgroundColor.setStroke()
            let ring = NSBezierPath(ovalIn: pieRect.insetBy(dx: -0.5, dy: -0.5))
            ring.lineWidth = 1.0
            ring.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            NSBezierPath(ovalIn: pieRect).stroke()
            ("无数据" as NSString).draw(at: NSPoint(x: cx - 18, y: cy - 5),
                withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor])
        }

        // 图例（饼图下方三行，留 16px 呼吸空间）
        let legendTopY: CGFloat = pieRect.minY - 16   // 饼图底留 16px
        let rowH: CGFloat = 14
        let dotR: CGFloat = 3
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
        ]

        func drawLegend(_ y: CGFloat, label: String, color: NSColor, value: Double) {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 2, y: y - dotR, width: dotR * 2, height: dotR * 2)).fill()
            (label as NSString).draw(at: NSPoint(x: rect.minX + 11, y: y - 4), withAttributes: labelAttrs)
            let valTxt = pieValid ? "\(Int(value))" : "?"
            (valTxt as NSString).draw(at: NSPoint(x: rect.maxX - 2 - (valTxt as NSString).size(withAttributes: valueAttrs).width, y: y - 5),
                withAttributes: valueAttrs)
        }
        // 三行图例：已采（顶）→ 待采 → 未找到（底）
        drawLegend(legendTopY - rowH * 0, label: "已采",   color: NSColor.systemGreen,        value: pieAdded)
        drawLegend(legendTopY - rowH * 1, label: "待采",   color: NSColor.controlAccentColor,  value: piePending)
        drawLegend(legendTopY - rowH * 2, label: "未找到", color: NSColor.systemGray,         value: pieNotfound)

        // 上市公司（与图例同款样式：label 10pt secondaryLabelColor 在左、value 11pt bold labelColor 右对齐）
        if pieValid {
            let totalY: CGFloat = legendTopY - rowH * 3   // 与三行图例保持相同行间距
            let total = Int(pieAdded + piePending + pieNotfound)
            ("上市公司总数" as NSString).draw(at: NSPoint(x: rect.minX + 2, y: totalY - 4),
                withAttributes: labelAttrs)
            let valTxt = "\(total)" as NSString
            let valSize = valTxt.size(withAttributes: valueAttrs)
            (valTxt as NSString).draw(at: NSPoint(x: rect.maxX - 2 - valSize.width, y: totalY - 5),
                withAttributes: valueAttrs)
        }
    }
}

// 状态行：左侧文字 [+ 右侧刷新图标按钮]。三行状态统一用本视图渲染，保证字体/颜色/边距完全一致
final class StatusRowView: NSView {
    var onRefresh: (() -> Void)?
    private let label: NSTextField
    private let button: NSButton?

    init(text: String, showRefresh: Bool = false) {
        label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        var b: NSButton? = nil
        if showRefresh {
            let icon = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)) ?? NSImage()
            let btn = NSButton(image: icon, target: nil, action: nil)
            btn.isBordered = false
            btn.imagePosition = .imageOnly
            btn.contentTintColor = .secondaryLabelColor
            btn.toolTip = "刷新状态"
            b = btn
        }
        button = b
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 18))
        addSubview(label)
        if let button = button {
            addSubview(button)
            button.target = self
            button.action = #selector(clickRefresh)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 14, y: (frame.height - label.frame.height) / 2)
        button?.frame.size = NSSize(width: 18, height: 16)
        button?.frame.origin = NSPoint(x: frame.width - 14 - 18, y: (frame.height - 16) / 2)
    }

    @objc private func clickRefresh() {
        button?.contentTintColor = .controlAccentColor
        onRefresh?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.button?.contentTintColor = .secondaryLabelColor
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
        case "review": DispatchQueue.main.async { ReviewWindowController.shared.show() }
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
    var jobsPending = -1
    var jobsUnseen = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        Notifier.shared.bootstrap()
        samples = History.load()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "werss …"
        statusItem.button?.toolTip = "微信公众号采集系统"
        rebuildMenu()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        // 深链/自动化：启动即打开审核窗口
        if CommandLine.arguments.contains("--open-review") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ReviewWindowController.shared.show() }
        }
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
        refreshJobs()
    }

    // 招聘帖待审统计（jobs.py stats）：菜单角标 + 有新帖时系统通知
    func refreshJobs() {
        jobsCmd("stats", timeout: 20) { [weak self] out in
            guard let self = self else { return }
            var d: [String: String] = [:]
            for line in out.split(separator: "\n") {
                let kv = line.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { d[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]).trimmingCharacters(in: .whitespaces) }
            }
            let p = Int(d["pending"] ?? "") ?? -1
            let u = Int(d["unseen"] ?? "") ?? 0
            let hadPrev = self.jobsPending >= 0
            let increased = hadPrev && p > self.jobsPending
            self.jobsPending = p
            self.jobsUnseen = u
            self.rebuildMenu()
            if increased && u > 0 {
                Notifier.shared.post(id: "werss-jobs",
                    title: "发现新招聘帖",
                    body: "新增待审，当前共 \(p) 篇待审核。点此打开审核窗口",
                    action: "review")
            }
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
        // 公司总数 = 已采(csv_added) + 待采(csv_pending) + 未找到(csv_notfound)
        // 注意这里用 CSV 台账口径，不用 feeds/slice：feeds 是 SQLite 订阅数(≈已采但不等于)；
        // slice 是队列剩余(≈待采也不等于)；未找到(csv_notfound)在 feeds/slice 口径里完全体现不出来
        let a = Int(d["csv_added"] ?? "-1") ?? -1      // 已采
        let p = Int(d["csv_pending"] ?? "-1") ?? -1    // 待采
        let n = Int(d["csv_notfound"] ?? "-1") ?? -1    // 未找到
        let total = (a < 0 || p < 0 || n < 0) ? -1 : (a + p + n)
        let aTxt = a < 0 ? "?" : "\(a)"
        let pTxt = p < 0 ? "?" : "\(p)"
        let nTxt = n < 0 ? "?" : "\(n)"
        let totalTxt = total < 0 ? "?" : "\(total)"
        statusItem.button?.toolTip = "已采\(aTxt) 待采\(pTxt) 未找到\(nTxt) 总值\(totalTxt) 文章\(d["articles"] ?? "?")"
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
        // 三行状态统一用 StatusRowView 渲染（字体/颜色/边距完全一致）；行1 右侧带刷新按钮
        let d = st.dict
        func addStatusRow(_ text: String, refresh: Bool = false) {
            let row = StatusRowView(text: text, showRefresh: refresh)
            if refresh { row.onRefresh = { [weak self] in self?.refreshNow() } }
            row.frame = NSRect(x: 0, y: 0, width: 340, height: 18)
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        addStatusRow("Docker \(d["docker"] ?? "?") · 容器 \(d["container"] ?? "?") · 应用 \(d["app"] ?? "?") · ego \(d["ego"] ?? "?")", refresh: true)
        // 公众号进度：已采(csv_added) + 待采(csv_pending) + 未找到(csv_notfound) = 公司总数
        // 用 CSV 台账口径，不用 feeds/slice，因为 feeds/slice 都漏算 csv_notfound
        let a = Int(d["csv_added"] ?? "-1") ?? -1
        let p = Int(d["csv_pending"] ?? "-1") ?? -1
        let n = Int(d["csv_notfound"] ?? "-1") ?? -1
        // 公众号进度（饼图 + 公众号trend + 文章trend）合并到一个 TrendView 里做三列布局
        addStatusRow("runner \(d["runner"] ?? "?") · 磁盘 \(d["disk_gb"] ?? "?")G · 备份 \(d["backup_days"] ?? "?")天前")
        // 微信读书授权 + 限流
        addStatusRow("微信读书授权 \(d["weread"] == "OK" ? "正常" : (d["weread"] == "FAIL" ? "失效待扫码" : (d["weread"] ?? "?"))) · 限流 \(d["throttled"] == "yes" ? "冷却中" : "无")")

        // 7 天趋势（三列布局：左饼图 + 右上公众号曲线 + 右下文章曲线）
        let trendItem = NSMenuItem()
        let trend = TrendView(frame: NSRect(x: 0, y: 0, width: 340, height: 150))
        trend.samples = samples
        trend.articlesSub = d["has_content"].flatMap { Int($0).map { "正文 \($0)" } } ?? ""
        trend.pieAdded = Double(a)
        trend.piePending = Double(p)
        trend.pieNotfound = Double(n)
        trend.liveFeeds = Double(d["feeds"] ?? "-1") ?? -1
        trend.liveArticles = Double(d["articles"] ?? "-1") ?? -1
        trendItem.view = trend
        menu.addItem(trendItem)

        // 招聘帖审核入口：有未看的新帖时加 ● 前缀并加粗
        menu.addItem(NSMenuItem.separator())
        let jobsTitle: String
        if jobsPending > 0 {
            jobsTitle = (jobsUnseen > 0 ? "● " : "") + "招聘帖审核（待审 \(jobsPending)）"
        } else {
            jobsTitle = "招聘帖审核（无待审）"
        }
        menu.addItem(mkItem(jobsTitle, action: #selector(openReview), bold: jobsUnseen > 0))

        if st.wereadFail || st.runnerDown || st.appDown || st.dockerDown {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(mkItem("── 待办（点击直达）──"))
            if st.wereadFail { menu.addItem(mkItem("→ 微信读书待扫码：ego 自动登录", action: #selector(openScan), bold: true)) }
            if st.appDown || st.dockerDown { menu.addItem(mkItem("→ 系统故障：立即保活修复", action: #selector(runKeepalive), bold: true)) }
            else if st.runnerDown { menu.addItem(mkItem("→ runner 未运行：拉起", action: #selector(runKeepalive), bold: true)) }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("打开管理页", action: #selector(openAdmin)))
        menu.addItem(mkItem("ego 自动登录 → 扫码页", action: #selector(openScan)))
        menu.addItem(mkItem("立即保活检查", action: #selector(runKeepalive)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("交接导出（打备份包）", action: #selector(doExport)))
        menu.addItem(mkItem("交接导入（选备份包）", action: #selector(doImport)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(mkItem("退出菜单栏", action: #selector(quit)))
        statusItem.menu = menu
    }

    @objc func refreshNow() { statusItem.button?.title = "werss …"; refresh() }
    @objc func openReview() { ReviewWindowController.shared.show() }
    @objc func openAdmin() { runSh("open http://localhost:8001/") }
    @objc func openScan() {
        statusItem.button?.title = "ego ⏳"
        // 立刻把 ego 拉到前台，避免脚本跑 5-30 秒期间用户看不到任何变化
        runSh("open -a 'ego lite' 2>/dev/null")
        runShCapture("bash '\(root)/bin/open_scan_page.sh'", timeout: 120) { [weak self] _ in
            // 脚本结束时再激活一次 ego，确保扫码窗口抢到焦点
            runSh("open -a 'ego lite' 2>/dev/null")
            DispatchQueue.main.async { self?.refresh() }
        }
    }
    @objc func runKeepalive() { runSh("bash '\(root)/bin/keepalive.sh'") }
    @objc func doExport() { NSWorkspace.shared.open(rootURL.appendingPathComponent("交接导出.command")) }
    @objc func doImport() { NSWorkspace.shared.open(rootURL.appendingPathComponent("交接导入.command")) }
    @objc func quit() { NSApplication.shared.terminate(nil) }
}

// 入口（多文件编译不能用顶层表达式，@main 是标准方式）
@main
struct WERSSMenubarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
