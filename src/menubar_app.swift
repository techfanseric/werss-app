// WERSS菜单栏：常驻状态图标 + 下拉菜单（状态总览/待办直达/常用操作）
// 编译: swiftc -O -o WERSS菜单栏.app/Contents/MacOS/main src/menubar_app.swift（见 bin/build_menubar.sh）
import AppKit

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

// 后台跑 bash 命令（不等待；需要输出时用 runShCapture）
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
        // 超时看门：超时直接放弃本轮（进程任其自然退出）
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { return }  // 已结束则无事
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var st = Status()
    var lastLevel = 0
    var menu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
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
            self.st = Status()
            self.st.dict = d
            self.render()
        }
    }

    func render() {
        let lvl = st.level
        switch lvl {
        case 3: statusItem.button?.title = "werss ✕"
        case 2: statusItem.button?.title = "werss ⚠️"
        default: statusItem.button?.title = "werss ✓"
        }
        let d = st.dict
        statusItem.button?.toolTip = "订阅\(d["feeds"] ?? "?") 文章\(d["articles"] ?? "?") 待采\(d["slice"] ?? "?")"
        rebuildMenu()
        // 状态升级为异常时补一条横幅（图标常驻为主，通知为辅）
        if lastLevel != 0 && lvl > lastLevel && lvl >= 2 {
            runSh("osascript -e 'display notification \"点菜单栏 werss 图标查看待办\" with title \"werss 状态变化\" sound name \"Sosumi\"'")
        }
        lastLevel = lvl
    }

    func mkItem(_ title: String, action: Selector? = nil, bold: Bool = false, indent: Bool = false) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: "")
        m.target = action == nil ? nil : self
        m.isEnabled = action != nil
        if bold {
            m.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        }
        if indent { m.indentationLevel = 1 }
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
            menu.addItem(mkItem("── 待办 ──"))
            if st.wereadFail {
                menu.addItem(mkItem("→ 微信读书待扫码：点此直达（自动登录）", action: #selector(openScan), bold: true))
            }
            if st.appDown || st.dockerDown {
                menu.addItem(mkItem("→ 系统故障：点此立即保活修复", action: #selector(runKeepalive), bold: true))
            } else if st.runnerDown {
                menu.addItem(mkItem("→ runner 未运行：点此拉起", action: #selector(runKeepalive), bold: true))
            }
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
    @objc func openAdmin() { runSh("open '\(ProcessInfo.processInfo.environment["WERSS_APP_URL"] ?? "http://localhost:8001")/' 2>/dev/null || open http://localhost:8001/") }
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
