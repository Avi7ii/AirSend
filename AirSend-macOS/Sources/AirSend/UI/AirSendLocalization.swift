import Foundation
import SwiftUI

enum AirSendLanguage: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }
}

enum AirSendLocalization {
    static let preferenceKey = "airsend.ui.language.v1"
    static let defaultLanguage = AirSendLanguage.simplifiedChinese

    static var currentLanguage: AirSendLanguage {
        let rawValue = UserDefaults.standard.string(forKey: preferenceKey)
        return rawValue.flatMap(AirSendLanguage.init(rawValue:)) ?? defaultLanguage
    }

    static func setCurrentLanguage(_ rawValue: String) {
        let language = AirSendLanguage(rawValue: rawValue) ?? defaultLanguage
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
    }

    static func localized(_ value: String) -> String {
        guard currentLanguage == .simplifiedChinese else { return value }
        if let translation = simplifiedChinese[value] {
            return translation
        }
        if value == value.uppercased(),
           let translation = simplifiedChinese.first(where: { $0.key.uppercased() == value })?.value {
            return translation
        }
        return localizedPattern(value) ?? value
    }

    private static func localizedPattern(_ value: String) -> String? {
        if value.hasPrefix("Send to ") {
            return "发送至 " + value.dropFirst("Send to ".count)
        }
        if value.hasPrefix("Receiving from "), value.hasSuffix("...") {
            let sender = value
                .dropFirst("Receiving from ".count)
                .dropLast(3)
            return "正在接收来自 \(sender) 的内容…"
        }
        if value.hasPrefix("Sending to "), value.hasSuffix("...") {
            let target = value
                .dropFirst("Sending to ".count)
                .dropLast(3)
            return "正在发送至 \(target)…"
        }
        if value.hasPrefix("Receive from "), value.hasSuffix("?") {
            let sender = value
                .dropFirst("Receive from ".count)
                .dropLast()
            return "接收来自 \(sender) 的内容？"
        }
        if value.hasPrefix("v"), value.hasSuffix(" downloaded") {
            return value.dropLast(" downloaded".count) + " 已下载"
        }
        if value == "just now" {
            return "刚刚"
        }
        if value.hasSuffix("m ago"), let minutes = Int(value.dropLast("m ago".count)) {
            return "\(minutes) 分钟前"
        }
        if value.hasSuffix("h ago"), let hours = Int(value.dropLast("h ago".count)) {
            return "\(hours) 小时前"
        }
        if value.hasSuffix("d ago"), let days = Int(value.dropLast("d ago".count)) {
            return "\(days) 天前"
        }
        if value.hasPrefix("Ports "), let marker = value.range(of: " · up ") {
            let ports = value[..<marker.lowerBound]
            let time = String(value[marker.upperBound...])
            return "端口 \(ports.dropFirst("Ports ".count)) · 已运行 \(localized(time))"
        }
        if value.hasPrefix("Protocol v"), value.contains(" · Config v"), value.contains(" · History v") {
            return value
                .replacingOccurrences(of: "Protocol", with: "协议")
                .replacingOccurrences(of: "Config", with: "配置")
                .replacingOccurrences(of: "History", with: "历史记录")
        }
        if value.hasPrefix("Clipboard "), value.contains(" · Screenshots ") {
            return value
                .replacingOccurrences(of: "Clipboard on", with: "剪贴板已开启")
                .replacingOccurrences(of: "Clipboard off", with: "剪贴板已关闭")
                .replacingOccurrences(of: "Screenshots watching", with: "截图监视中")
                .replacingOccurrences(of: "Screenshots unavailable", with: "截图不可用")
                .replacingOccurrences(of: "Screenshots off", with: "截图已关闭")
        }
        if value.hasSuffix(" available"), let count = Int(value.dropLast(" available".count)) {
            return "\(count) 项可用"
        }
        if value.hasSuffix(" active transfer") || value.hasSuffix(" active transfers") {
            let count = value.split(separator: " ").first ?? "0"
            return "\(count) 个活动传输"
        }
        if value.hasSuffix(" device visible") || value.hasSuffix(" devices visible") {
            let count = value.split(separator: " ").first ?? "0"
            return "可见 \(count) 台设备"
        }
        if value.hasPrefix("HTTPS · checked ") || value.hasPrefix("HTTP compatibility · checked ") {
            let mode = value.hasPrefix("HTTPS") ? "HTTPS" : "HTTP 兼容模式"
            let marker = " · checked "
            guard let range = value.range(of: marker) else { return nil }
            return "\(mode) · \(localized(String(value[range.upperBound...])))检查"
        }
        if value == "HTTPS · live state pending" || value == "HTTP compatibility · live state pending" {
            return value.hasPrefix("HTTPS") ? "HTTPS · 正在获取实时状态" : "HTTP 兼容模式 · 正在获取实时状态"
        }
        if value.hasPrefix("satisfied-") || value.hasPrefix("unsatisfied-") {
            return value
                .replacingOccurrences(of: "unsatisfied", with: "网络不可用")
                .replacingOccurrences(of: "satisfied", with: "网络正常")
                .replacingOccurrences(of: "wifi", with: "Wi-Fi")
                .replacingOccurrences(of: "expensive:true", with: "计费网络")
                .replacingOccurrences(of: "expensive:false", with: "非计费网络")
                .replacingOccurrences(of: "constrained:true", with: "受限网络")
                .replacingOccurrences(of: "constrained:false", with: "非受限网络")
                .replacingOccurrences(of: "-", with: " · ")
        }
        if value.hasSuffix(" · ready") {
            return String(value.dropLast("ready".count)) + "就绪"
        }
        if value.hasPrefix("ID ") {
            return value
        }
        if value.hasPrefix("Showing "), value.hasSuffix(" visible devices on the current LAN.") {
            let count = value
                .dropFirst("Showing ".count)
                .dropLast(" visible devices on the current LAN.".count)
            return "当前局域网内显示 \(count) 台可见设备。"
        }
        if value.hasPrefix("Showing 1 visible device") {
            return "当前局域网内显示 1 台可见设备。"
        }
        if value == "Clear Sent History?" {
            return "清除已发送历史记录？"
        }
        if value == "Clear Received History?" {
            return "清除已接收历史记录？"
        }
        return nil
    }

    private static let simplifiedChinese: [String: String] = [
        "Status": "状态",
        "Devices": "设备",
        "Transfers": "传输",
        "Settings": "设置",
        "Console": "控制台",
        "Runtime health, automation, and quick actions.": "运行状态、自动化与快捷操作。",
        "Current target, nearby devices, and discovery.": "当前目标、附近设备与发现。",
        "Send and receive activity, progress, and history.": "发送与接收活动、进度和历史记录。",
        "Automation, receiving, network, diagnostics, and identity.": "语言、自动化、接收、网络、诊断与身份。",
        "General": "通用",
        "Language": "语言",
        "Choose the language used throughout AirSend.": "选择 AirSend 全局使用的语言。",
        "Health": "运行状况",
        "Quick Actions": "快捷操作",
        "Recent Activity": "最近活动",
        "Current Target": "当前目标",
        "LAN Devices": "局域网设备",
        "Manual Devices": "手动设备",
        "Activity": "活动",
        "Transfer Queue": "传输队列",
        "Send Options": "发送选项",
        "Receive Options": "接收选项",
        "Automation": "自动化",
        "Receiving": "接收",
        "Trusted Devices": "受信任设备",
        "Network": "网络",
        "History": "历史记录",
        "Startup & Updates": "启动与更新",
        "Diagnostics": "诊断",
        "Diagnostic Tools": "诊断工具",
        "Logs": "日志",
        "Identity": "身份",
        "About": "关于",
        "Send": "发送",
        "Receive": "接收",
        "Clipboard Sync": "剪贴板同步",
        "Sync copied text and images to the current Android target.": "将复制的文本和图片同步到当前 Android 目标。",
        "Screenshot Sync": "截图同步",
        "Send new macOS screenshots to one trusted target.": "将新的 macOS 截图发送到一个受信任目标。",
        "Watch new screenshots and send them to one trusted target.": "监视新截图并发送到一个受信任目标。",
        "Screenshot watcher": "截图监视器",
        "Run Diagnostics": "运行诊断",
        "Refresh Devices": "刷新设备",
        "Refreshing…": "正在刷新…",
        "Restart Runtime": "重启运行服务",
        "No recent activity": "暂无最近活动",
        "Discovery, transfers, and diagnostics will appear here.": "设备发现、传输和诊断记录将显示在这里。",
        "No devices found": "未发现设备",
        "Make sure the other device is on the same LAN, then rescan.": "请确认另一台设备位于同一局域网，然后重新扫描。",
        "No manual devices": "暂无手动设备",
        "Direct endpoints appear here.": "手动添加的直连设备将显示在这里。",
        "Add Manual Device": "添加手动设备",
        "Add by IP": "通过 IP 添加",
        "Use Broadcast": "使用广播",
        "Choose Files": "选择文件",
        "Choose an online target first": "请先选择在线目标",
        "Nearby Targets": "附近目标",
        "Receive Requests": "接收请求",
        "No active requests": "暂无活动请求",
        "Send Clipboard": "发送剪贴板",
        "Send Files…": "发送文件…",
        "Broadcast to All": "广播至所有设备",
        "Target Offline (Select another)": "目标离线（请选择其他设备）",
        "Requesting...": "正在请求…",
        "Sent!": "发送成功！",
        "Saved!": "保存成功！",
        "KNOWN DEVICES": "已知设备",
        "OTHER DEVICES": "其他设备",
        "  Searching nearby...": "  正在搜索附近设备…",
        "Waiting for phone...": "正在等待手机…",
        "Update ready, restart now?": "更新已就绪，立即重启？",
        "Text or image from the clipboard": "剪贴板中的文本或图片",
        "Files": "文件",
        "Images & Video": "图片与视频",
        "No trusted devices": "暂无受信任设备",
        "Trust is only needed for unattended receiving and automation.": "无人值守接收与自动化功能需要信任设备。",
        "Trust Device…": "信任设备…",
        "Compatibility Mode": "兼容模式",
        "Use the simpler HTTP path on tricky networks.": "在复杂网络中使用更简单的 HTTP 通道。",
        "Current transport": "当前传输协议",
        "Launch at login": "登录时启动",
        "Start AirSend when you sign in.": "登录系统时启动 AirSend。",
        "Auto-check for updates": "自动检查更新",
        "Check in the background and download new builds automatically.": "在后台检查并自动下载新版本。",
        "Check for Updates": "检查更新",
        "Export Logs": "导出日志",
        "Clear Logs": "清除日志",
        "Fingerprint": "指纹",
        "Reset Identity": "重置身份",
        "Clear Devices": "清除设备",
        "Version": "版本",
        "Open AirSend Repository": "打开 AirSend 仓库",
        "Visible": "可见",
        "Remembered": "已记住",
        "Transport": "传输协议",
        "Broadcast": "广播",
        "Same LAN": "同一局域网",
        "Selected": "已选择",
        "Manual": "手动",
        "Online": "在线",
        "Offline": "离线",
        "Revoke": "撤销信任",
        "No sent files yet": "暂无已发送文件",
        "No received files yet": "暂无已接收文件",
        "Shared files and clipboard sends will appear here.": "发送的文件与剪贴板内容将显示在这里。",
        "Incoming transfers will appear here.": "收到的传输将显示在这里。",
        "From": "来自",
        "To": "发送至",
        "Multiple files": "多个文件",
        "Android package": "Android 安装包",
        "Image file": "图片文件",
        "Video file": "视频文件",
        "Audio file": "音频文件",
        "PDF document": "PDF 文档",
        "Archive file": "压缩文件",
        "Presentation": "演示文稿",
        "Spreadsheet": "电子表格",
        "Word processing document": "文字处理文档",
        "HTML document": "HTML 文档",
        "Markdown document": "Markdown 文档",
        "Structured data file": "结构化数据文件",
        "Source code file": "源代码文件",
        "Text file": "文本文件",
        "Document": "文档",
        "File": "文件",
        "Waiting": "等待中",
        "Preparing": "准备中",
        "Transferring": "传输中",
        "Completed": "已完成",
        "Failed": "失败",
        "Cancelled": "已取消",
        "Declined": "已拒绝",
        "No log entries": "暂无日志",
        "Run diagnostics to refresh the log view.": "运行诊断以刷新日志。",
        "Receive requests": "接收请求",
        "Full Access": "完全开放",
        "Trusted Only": "仅受信任设备",
        "Off": "关闭",
        "Items per direction": "每个方向保留数量",
        "Ready": "就绪",
        "Waiting for devices": "正在等待设备",
        "Network unavailable": "网络不可用",
        "Waiting for a usable network path": "正在等待可用网络",
        "Receiver stopped": "接收服务已停止",
        "Target Offline": "目标离线",
        "Choose another device or rescan": "请选择其他设备或重新扫描",
        "All Devices": "所有设备",
        "Broadcast to every online device": "广播到所有在线设备",
        "HTTP Compatibility": "HTTP 兼容模式",
        "HTTPS Default": "HTTPS 默认模式",
        "Watching": "监视中",
        "Active": "活动",
        "Idle": "空闲",
        "Available": "可用",
        "Unavailable": "不可用",
        "Listening": "正在监听",
        "Stopped": "已停止",
        "Writable": "可写",
        "Needs attention": "需要处理",
        "Network path": "网络路径",
        "Receiver": "接收服务",
        "TLS identity": "TLS 身份",
        "Storage": "存储",
        "Downloads and media destinations": "下载与媒体保存位置",
        "Runtime": "运行时",
        "Capabilities": "功能能力",
        "Compatibility mode": "兼容模式",
        "Open AirSend…": "打开 AirSend…",
        "All Devices (Broadcast)": "所有设备（广播）",
        "Quit AirSend": "退出 AirSend",
        "Clear History": "清除历史记录",
        "Cancel": "取消",
        "Accept": "接受",
        "Decline": "拒绝",
        "OK": "好",
        "No Devices Available to Trust": "没有可供信任的设备",
        "Discover an untrusted device on the current LAN, then try again.": "请先在当前局域网中发现一台尚未信任的设备，然后重试。",
        "Trust a Device": "信任设备",
        "Trusted devices may send files without a prompt when receiving is limited to trusted devices. Only trust devices you control.": "当接收范围设为仅受信任设备时，受信任设备可无需确认直接发送文件。请只信任你控制的设备。",
        "Trust Device": "信任设备",
        "Clear AirSend logs?": "清除 AirSend 日志？",
        "This removes the local diagnostic log history.": "这会移除本机的诊断日志历史记录。",
        "AirSend will remember this endpoint and probe it directly. Add its fingerprint to use verified HTTPS.": "AirSend 会记住此端点并直接探测。填写设备指纹即可使用经过验证的 HTTPS。",
        "Add": "添加",
        "Living Room Phone": "客厅手机",
        "Optional SHA-256 fingerprint": "可选的 SHA-256 指纹",
        "Name": "名称",
        "Address": "地址",
        "Port": "端口",
        "Device Could Not Be Added": "无法添加设备",
        "Open Repository": "打开仓库",
        "Continue": "继续",
        "Updates Unavailable": "无法更新",
        "This build cannot use automatic updates.": "此构建无法使用自动更新。",
        "Check for Update": "检查更新",
        "This removes completed and failed transfer records. Saved files are not deleted.": "这会移除已完成和失败的传输记录，但不会删除已保存的文件。",
    ]
}

@MainActor
func AirSendText(_ value: String) -> Text {
    Text(verbatim: AirSendLocalization.localized(value))
}
