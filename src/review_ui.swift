// review_ui.swift —— 招聘帖审核窗口（数据来自 bin/jobs.py：规则粗筛 + MiniMax 精判 + 发布状态库）
// 与 menubar_app.swift 同模块编译（bash bin/build_menubar.sh）；独立成文件以便离屏渲染预览。
// 本文件同时承载通用进程/路径助手（runSh 等），menubar_app.swift 直接使用。
import AppKit
import SwiftUI

// ---- 路径与进程助手（menubar 主体也用）----

// 预览/测试可注入 WERSS_ROOT；正式运行取 .app 上级目录 = werss-app 根
let rootURL = Bundle.main.bundleURL.deletingLastPathComponent()
let root = ProcessInfo.processInfo.environment["WERSS_ROOT"] ?? rootURL.path

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
        // 并行持续读管道：输出超过管道缓冲区(64KB)时，"先等退出再读"会死锁
        // （审核列表 JSON ~160KB，曾在旧模式下超时被杀、窗口全空）
        var outData = Data()
        let eof = DispatchGroup()
        eof.enter()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                eof.leave()
            } else {
                outData.append(chunk)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { p.terminate() }
        }
        p.waitUntilExit()
        let _ = eof.wait(timeout: .now() + 5)
        pipe.fileHandleForReading.readabilityHandler = nil
        let out = String(data: outData, encoding: .utf8) ?? ""
        DispatchQueue.main.async { done(out) }
    }
}

func jobsCmd(_ sub: String, timeout: Double, done: @escaping (String) -> Void) {
    runShCapture("python3 '\(root)/bin/jobs.py' " + sub + " 2>&1", timeout: timeout, done: done)
}

// ---- 数据模型 ----

struct JobItem: Identifiable {
    let id: String; let mpName: String; let title: String; let url: String
    let date: String; let time: String
    let type: String; let sessionYear: Int; let hasYear: Bool
    let company: String; let positions: String; let reason: String
    var status: String   // pending / published / skipped
    let stale: Bool; let auto: Bool
    var publishedAt: Double

    func with(status s: String, publishedAt p: Double? = nil) -> JobItem {
        var c = self
        c.status = s
        if let p = p { c.publishedAt = p }
        return c
    }
}

final class ReviewVM: ObservableObject {
    @Published var items: [JobItem] = []
    @Published var counts: [String: Int] = [:]
    @Published var meta: [String: String] = [:]
    @Published var filter = "pending"
    @Published var search = ""
    @Published var hideStale = false
    @Published var loading = false
    @Published var scanning = false
    @Published var publishingDay: String?
    @Published var busy: Set<String> = []
    @Published var message = ""
    private var autoTimer: Timer?

    // 当前筛选（状态 + 待审页的旧文开关 + 搜索框）下的可见条目
    var visible: [JobItem] {
        var out = filter == "all" ? items : items.filter { $0.status == filter }
        if filter == "pending" && hideStale { out = out.filter { !$0.stale } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter {
                [$0.title, $0.mpName, $0.company, $0.positions, $0.type]
                    .contains { $0.lowercased().contains(q.lowercased()) }
            }
        }
        return out
    }

    // 按发现日期分组（items 已按时间倒序）
    var groups: [(date: String, items: [JobItem], pending: Int, stale: Int)] {
        var order: [String] = []
        var by: [String: [JobItem]] = [:]
        for i in visible {
            if by[i.date] == nil { order.append(i.date) }
            by[i.date, default: []].append(i)
        }
        return order.map { g in
            let arr = by[g]!
            return (date: g, items: arr,
                    pending: arr.filter { $0.status == "pending" }.count,
                    stale: arr.filter { $0.stale }.count)
        }
    }

    var publishConfigured: Bool { meta["publish_configured"] == "true" }

    // ---- 窗口可见期间 60s 静默刷新；发布/扫描进行中跳过 ----
    func startAutoRefresh() {
        stopAutoRefresh()
        autoTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self, self.publishingDay == nil, !self.scanning else { return }
            self.reload(quiet: true)
        }
    }
    func stopAutoRefresh() {
        autoTimer?.invalidate()
        autoTimer = nil
    }

    func reload(quiet: Bool = false) {
        loading = true
        jobsCmd("list --json", timeout: 30) { [weak self] out in
            guard let self = self else { return }
            self.loading = false
            guard !out.isEmpty else {
                if !quiet { self.message = "加载失败：命令无输出" }
                return
            }
            guard let data = out.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                if !quiet {  // 解析失败亮出原始输出开头，便于定位（不再"静默全空"）
                    self.message = "加载失败(解析JSON)：" + String(out.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                }
                return
            }
            let arr = obj["items"] as? [[String: Any]] ?? []
            self.items = arr.map { d in
                let year = d["session_year"] as? Int
                return JobItem(
                    id: d["id"] as? String ?? "",
                    mpName: d["mp_name"] as? String ?? "",
                    title: d["title"] as? String ?? "",
                    url: d["url"] as? String ?? "",
                    date: d["date"] as? String ?? "",
                    time: d["time"] as? String ?? "",
                    type: d["type"] as? String ?? "",
                    sessionYear: year ?? 0,
                    hasYear: year != nil,
                    company: d["company"] as? String ?? "",
                    positions: d["positions"] as? String ?? "",
                    reason: d["reason"] as? String ?? "",
                    status: d["status"] as? String ?? "pending",
                    stale: d["stale"] as? Bool ?? false,
                    auto: d["auto"] as? Bool ?? false,
                    publishedAt: d["published_at"] as? Double ?? 0)
            }
            var cc: [String: Int] = [:]
            if let c = obj["counts"] as? [String: Any] {
                for (k, v) in c { if let i = v as? Int { cc[k] = i } }
            }
            self.counts = cc
            if let m = obj["meta"] as? [String: Any] {
                var mm: [String: String] = [:]
                for (k, v) in m { mm[k] = String(describing: v) }
                self.meta = mm
            }
        }
    }

    // 单篇操作：成功则本地原位更新（不整表重载，避免闪烁/滚动位置丢失）
    private func act(_ sub: String, _ id: String, to status: String) {
        busy.insert(id)
        jobsCmd("\(sub) '\(id)'", timeout: 60) { [weak self] out in
            guard let self = self else { return }
            self.busy.remove(id)
            self.message = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.hasPrefix("发布失败") { self.apply(id: id, status: status) }
        }
    }
    func publish(_ id: String) { act("publish", id, to: "published") }
    func skip(_ id: String) { act("skip", id, to: "skipped") }
    func undo(_ id: String) { act("undo", id, to: "pending") }

    private func apply(id: String, status: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let old = items[idx].status
        var it = items[idx]
        it = it.with(status: status, publishedAt: status == "published" ? Date().timeIntervalSince1970 : nil)
        items[idx] = it
        if old != status {
            counts[old, default: 0] = max(0, (counts[old] ?? 0) - 1)
            counts[status, default: 0] = (counts[status] ?? 0) + 1
        }
    }

    func rescan() {
        scanning = true
        message = "正在扫描新文章并模型精判…（约 1–3 分钟）"
        jobsCmd("scan --quiet", timeout: 900) { [weak self] _ in
            self?.scanning = false
            self?.reload(quiet: true)
            self?.message = "扫描完成"
        }
    }

    // 一键发布当日：先确认（含旧文警示），逐篇串行，本地即时反馈进度
    func confirmPublishDay(date: String, count: Int, stale: Int) {
        guard count > 0 else { return }
        let a = NSAlert()
        a.alertStyle = stale > 0 ? .warning : .informational
        a.messageText = "一键发布「\(jobDateLabel(date))」待审 \(count) 篇？"
        a.informativeText = stale > 0
            ? "其中含旧文 \(stale) 篇（届别过期），确认后将一并发布。"
            : "将逐篇调用发布接口并标记为已发布。"
        a.addButton(withTitle: "发布")
        a.addButton(withTitle: "取消")
        if a.runModal() == .alertFirstButtonReturn { publishDay(date) }
    }

    func publishDay(_ date: String) {
        let ids = items.filter { $0.date == date && $0.status == "pending" }.map { $0.id }
        guard !ids.isEmpty, publishingDay == nil else { return }
        publishingDay = date
        var ok = 0, fail = 0
        func next(_ i: Int) {
            guard i < ids.count else {
                publishingDay = nil
                message = "当日发布完成：成功 \(ok)，失败 \(fail)"
                reload(quiet: true)   // 以状态库为准校准计数
                return
            }
            message = "发布中 \(i + 1)/\(ids.count)…"
            jobsCmd("publish '\(ids[i])'", timeout: 60) { out in
                if out.hasPrefix("发布失败") || out.contains("HTTP 4") || out.contains("HTTP 5") { fail += 1 } else { ok += 1 }
                self.apply(id: ids[i], status: "published")
                next(i + 1)
            }
        }
        next(0)
    }
}

// ---- 展示助手 ----

func jobDateLabel(_ s: String) -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    guard let d = df.date(from: s) else { return s }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "今天" }
    if cal.isDateInYesterday(d) { return "昨天" }
    let d2 = DateFormatter()
    d2.dateFormat = "M月d日 EEEE"
    d2.locale = Locale(identifier: "zh_CN")
    return d2.string(from: d)
}

func jobTypeColor(_ t: String) -> Color {
    switch t {
    case "校招": return .blue
    case "社招": return .purple
    case "实习": return .green
    case "内推": return .pink      // 不用 orange——那是「旧文」警示色
    case "宣讲会": return .teal
    case "流程公告": return Color(nsColor: .systemGray)
    default: return .secondary
    }
}

struct JobTag: View {
    let text: String; let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// ---- 单行 ----

struct JobRow: View {
    @ObservedObject var vm: ReviewVM
    let item: JobItem
    @State private var titleHover = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            info
            Spacer(minLength: 12)
            controls
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openURL() }
        .contextMenu {
            Button("打开原文") { openURL() }
            Button("拷贝链接") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url, forType: .string) }
                .disabled(item.url.isEmpty)
            Divider()
            if item.status == "pending" {
                Button("发布") { vm.publish(item.id) }
                Button("不发布") { vm.skip(item.id) }
            } else {
                Button("恢复待审") { vm.undo(item.id) }
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 标题：可点链接样式（悬停下划线+手型）；双击整行也可打开
            if URL(string: item.url) != nil, !item.url.isEmpty {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .underline(titleHover)
                    .lineLimit(2)
                    .onHover { h in
                        titleHover = h
                        if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .onTapGesture { openURL() }
            } else {
                Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
            }
            HStack(spacing: 6) {
                tags
                Text(metaLine).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(metaLine)   // 截断时悬停看全文
            }
            if item.status == "skipped" && item.auto && !item.reason.isEmpty {
                Text("模型判定非招聘：\(item.reason)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var tags: some View {
        HStack(spacing: 4) {
            if !item.type.isEmpty { JobTag(text: item.type, color: jobTypeColor(item.type)) }
            if item.hasYear { JobTag(text: "\(item.sessionYear)届", color: .accentColor) }
            if item.stale { JobTag(text: "旧文", color: .orange) }
        }
    }

    private var metaLine: String {
        var parts = ["\(item.mpName) · \(item.time)"]
        if !item.company.isEmpty { parts.append(item.company) }
        if !item.positions.isEmpty { parts.append(item.positions) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var controls: some View {
        let acting = vm.busy.contains(item.id) || vm.publishingDay != nil
        Group {
            if acting {
                ProgressView().controlSize(.small)
            } else {
                switch item.status {
                case "pending":
                    HStack(spacing: 10) {
                        Button("不发布") { vm.skip(item.id) }
                            .buttonStyle(.link).font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("发布") { vm.publish(item.id) }
                            .controlSize(.small)
                    }
                case "published":
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                            Text(publishTimeText).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Button("撤回") { vm.undo(item.id) }
                            .buttonStyle(.link).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                default:
                    HStack(spacing: 6) {
                        Text(item.auto ? "模型已忽略" : "已忽略")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Button("恢复") { vm.undo(item.id) }
                            .buttonStyle(.link).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minWidth: 120, alignment: .trailing)   // 固定尾部宽度：不同状态的控件右缘对齐
    }

    private var publishTimeText: String {
        guard item.publishedAt > 0 else { return "已发布" }
        let df = DateFormatter()
        df.dateFormat = "M-d HH:mm 已发布"
        return df.string(from: Date(timeIntervalSince1970: item.publishedAt))
    }

    private func openURL() {
        if let u = URL(string: item.url), !item.url.isEmpty { NSWorkspace.shared.open(u) }
    }
}

// ---- 窗口主体 ----

struct ReviewView: View {
    @ObservedObject var vm: ReviewVM
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    private var toolbar: some View {
        // 搜索框与状态 tab 都是带描边的独立控件；间距 20pt（HIG 上限附近）
        // 让两组控件一眼可辨，搜索框本身收窄至 180，placeholder 仍能完整显示。
        HStack(spacing: 20) {
            searchField
            Picker("筛选", selection: $vm.filter) {
                Text("待审 \(vm.counts["pending"] ?? 0)").tag("pending")
                Text("已发布 \(vm.counts["published"] ?? 0)").tag("published")
                Text("已忽略 \(vm.counts["skipped"] ?? 0)").tag("skipped")
                Text("全部 \(vm.counts["total"] ?? 0)").tag("all")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(minWidth: 280, idealWidth: 340)
            Spacer(minLength: 8)
            Button { vm.hideStale.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: vm.hideStale ? "checkmark.square.fill" : "square")
                    Text("隐藏旧文").font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(vm.hideStale ? Color.accentColor : Color.secondary)
            .help("在待审列表中隐藏届别过期的旧帖（历史回填文章）")
            .disabled(vm.filter != "pending")
            Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("刷新列表 (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            Button { vm.rescan() } label: {
                if vm.scanning { ProgressView().controlSize(.small) } else { Text("重新扫描") }
            }
            .disabled(vm.scanning)
            .help("扫描新文章并模型精判（约 1–3 分钟）")
        }
        .padding(10)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField("搜索 公司 / 标题 / 岗位", text: $vm.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !vm.search.isEmpty {
                Button { vm.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tertiary)
                    .help("清空")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor).opacity(0.7)))
        .frame(width: 180)
        .onTapGesture { searchFocused = true }
    }

    @ViewBuilder private var content: some View {
        if vm.visible.isEmpty {
            VStack(spacing: 8) {
                if vm.loading && vm.items.isEmpty { ProgressView() }
                Image(systemName: emptyIcon).font(.system(size: 28)).foregroundStyle(.quaternary)
                Text(emptyText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(vm.groups, id: \.date) { g in
                    Section {
                        ForEach(g.items) { JobRow(vm: vm, item: $0) }
                    } header: {
                        sectionHeader(g)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func sectionHeader(_ g: (date: String, items: [JobItem], pending: Int, stale: Int)) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(jobDateLabel(g.date)).font(.system(size: 12, weight: .semibold))
            Text(g.date).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text("\(g.items.count) 篇").font(.system(size: 10)).foregroundStyle(.secondary)
            if g.stale > 0 {
                Text("含旧文 \(g.stale)").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Spacer()
            if vm.filter == "pending" {
                Button {
                    vm.confirmPublishDay(date: g.date, count: g.pending, stale: g.stale)
                } label: {
                    Label("一键发布", systemImage: "paperplane.fill")
                }
                .controlSize(.small)
                .disabled(vm.publishingDay != nil || g.pending == 0)
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyIcon: String {
        switch vm.filter {
        case "published": return "paperplane"
        case "skipped": return "archivebox"
        default: return "checkmark.seal"
        }
    }

    private var emptyText: String {
        let q = vm.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { return "没有匹配「\(q)」的帖子" }
        switch vm.filter {
        case "published": return "还没有发布过帖子；在「待审」里点「发布」试试"
        case "skipped": return "没有已忽略的帖子"
        case "pending": return vm.hideStale ? "没有待审的招聘帖（旧文已隐藏）" : "没有待审的招聘帖"
        default: return "暂无数据"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if vm.scanning {
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("扫描中…").foregroundStyle(.secondary) }
            } else if vm.publishingDay != nil {
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("发布中…").foregroundStyle(.secondary) }
            } else if !vm.message.isEmpty {
                Text(vm.message).lineLimit(1).truncationMode(.head)
            } else {
                Text("最近扫描：\(lastScanText)").foregroundStyle(.secondary)
            }
            Spacer()
            Text(vm.publishConfigured
                 ? "发布目标：\(vm.meta["publish_host"] ?? "已配置")"
                 : "未配置发布接口 · 发布仅本地标记")
                .foregroundStyle(vm.publishConfigured ? Color.secondary : Color.orange)
                .help(vm.publishConfigured
                      ? "「发布」将 POST 到该接口"
                      : "在 config.env 配置 JOBS_PUBLISH_URL 后，「发布」将 POST 到该接口")
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var lastScanText: String {
        let s = vm.meta["last_scan"] ?? ""
        guard s.count >= 16 else { return s.isEmpty ? "—" : s }
        // "2026-09-25T00:15:34" → "09-25 00:15"
        let body = s.prefix(16).replacingOccurrences(of: "T", with: " ")
        return String(body.dropFirst(5))
    }
}

final class ReviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ReviewWindowController()
    let vm = ReviewVM()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "招聘帖审核"
        win.subtitle = "按发现日期分组 · 最新在前"
        win.contentView = NSHostingView(rootView: ReviewView(vm: vm))
        win.center()   // 先给默认位置
        super.init(window: win)
        win.delegate = self
        win.setFrameAutosaveName("WERSSReviewWindow")   // 再挂记忆：有历史位置则覆盖居中
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runSh("python3 '\(root)/bin/jobs.py' seen")   // 打开窗口即视为已看，清菜单角标
        vm.reload()
        vm.startAutoRefresh()
    }

    func windowWillClose(_ notification: Notification) {
        vm.stopAutoRefresh()
    }
}
