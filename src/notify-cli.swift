// werss-notify：WERSS控制台.app 内置通知组件（随 app bundle 以其身份发通知）。
// 用法: werss-notify <title> <subtitle> <body> <sound> <group>
//   sound 传 "default" 用系统默认声，否则传系统声名（如 Glass/Sosumi，不带扩展名）
// 退出码: 0=已投递 2=被拒绝(权限) 3=其他错误
// 点击通知会启动 WERSS控制台.app（bash main），由其按状态分发动作。
import Foundation
import UserNotifications

let args = CommandLine.arguments
let title = args.count > 1 ? args[1] : "werss"
let subtitle = args.count > 2 ? args[2] : ""
let body = args.count > 3 ? args[3] : ""
let soundName = args.count > 4 ? args[4] : "default"
let group = args.count > 5 ? args[5] : "werss"

// 必须跑在 .app bundle 内（bundle id 即通知归属）
guard Bundle.main.bundleIdentifier != nil else {
    FileHandle.standardError.write("not in app bundle\n".data(using: .utf8)!)
    exit(3)
}

let center = UNUserNotificationCenter.current()
let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 3

func finish(_ code: Int32) {
    exitCode = code
    sem.signal()
}

center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
    guard granted else {
        FileHandle.standardError.write("DENIED\n".data(using: .utf8)!)
        finish(2)
        return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    if !subtitle.isEmpty { content.subtitle = subtitle }
    if !body.isEmpty { content.body = body }
    if soundName == "default" {
        content.sound = .default
    } else {
        content.sound = UNNotificationSound(named: UNNotificationSoundName(soundName + ".aiff"))
    }
    content.threadIdentifier = group
    let req = UNNotificationRequest(identifier: group + "-" + UUID().uuidString,
                                    content: content, trigger: nil)
    center.add(req) { err in
        if let err = err {
            FileHandle.standardError.write("\(err)\n".data(using: .utf8)!)
            finish(3)
        } else {
            finish(0)
        }
    }
}

_ = sem.wait(timeout: .now() + 120)
exit(exitCode)
