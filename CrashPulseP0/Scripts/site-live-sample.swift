import AppKit
import SwiftUI

// Renders the Live panel from a fixed sample snapshot for the product site (Website/site).
// Built by Scripts/render-site-shots.zsh together with the app sources; it is not part of the app.
// Compiled against the app sources without changing them.
@MainActor
func render(_ view: AnyView, dark: Bool, to url: URL) {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(rootView: view
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = appearance
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

let now = Date()
var nextPID: Int32 = 400
func row(_ name: String, _ path: String, cpu: Double, watts: Double) -> ProcessRow {
    nextPID += 37
    return ProcessRow(pid: nextPID, name: name, path: path,
                      identity: ProcessIdentity(pid: nextPID, startSeconds: 1_790_000_000, startMicroseconds: 0),
                      effectiveUID: 501, parentPID: 1, sampledAt: now, cpuPercent: cpu,
                      residentBytes: 200_000_000, footprintBytes: 150_000_000, state: .sampled, issues: [],
                      cpuWindow: nil,
                      cpuPower: ProcessCPUPower(before: 0, after: UInt64(watts * 1e9 * 5), elapsedSeconds: 5))
}

let xcode = "/Applications/Xcode.app/Contents"
let rows = [
    row("Xcode", "\(xcode)/MacOS/Xcode", cpu: 18.2, watts: 0.21),
    row("swift-frontend", "\(xcode)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", cpu: 74.5, watts: 0.92),
    row("clang", "\(xcode)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", cpu: 12.1, watts: 0.15),
    row("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", cpu: 3.4, watts: 0.06),
    row("Safari Web Content", "/Applications/Safari.app/Contents/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", cpu: 6.8, watts: 0.09),
    row("photoanalysisd", "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd", cpu: 9.6, watts: 0.08),
    row("mds_stores", "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds_stores", cpu: 5.9, watts: 0.05),
    row("Music", "/System/Applications/Music.app/Contents/MacOS/Music", cpu: 2.7, watts: 0.04),
    row("Mail", "/System/Applications/Mail.app/Contents/MacOS/Mail", cpu: 1.1, watts: 0.02),
    row("Finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", cpu: 0.9, watts: 0.01),
]
let snapshot = Snapshot(sampledAt: now, scanMilliseconds: 4, coverage: Coverage(enumerated: rows.count, identity: rows.count, resource: rows.count, cpu: rows.count, memory: rows.count), enumerationIssue: nil,
                        rows: rows, powerSupply: .adapter)
let activity = (0..<36).map { index in
    let wave = 34 + 10 * sin(Double(index) / 3) + (index > 24 ? 109 : 0)
    return ActivityPoint(at: now.addingTimeInterval(Double(index - 35) * 5), measuredCPUPercent: wave, triggerCPUPercent: nil)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let view = AnyView(PanelChrome(status: PanelStatus(text: "Watching, plugged in", color: Pulse.watching),
                               monitoring: true, showsTabs: true, tab: .constant(.live),
                               onToggleMonitoring: {}, openSettings: {}) {
    LiveView(snapshot: snapshot, activity: activity, monitoring: true, isVisible: true, onResume: {})
})
MainActor.assumeIsolated {
    _ = NSApplication.shared
    render(view, dark: false, to: output.appendingPathComponent("live-light.png"))
    render(view, dark: true, to: output.appendingPathComponent("live-dark.png"))
}
