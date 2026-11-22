// Renders a full-page PNG of a URL with WebKit, the engine Safari uses, to check the site
// the way most Mac visitors will see it (including the New York serif behind ui-serif).
//
//   xcrun swiftc -O snap-webkit.swift -o /tmp/snap-webkit
//   /tmp/snap-webkit http://127.0.0.1:8765/ 390 dark /tmp/phone-dark.png
//
// The window is ordered on screen at almost zero opacity: WebKit pauses CSS animations in
// hidden windows, which would leave the hero trace at its first frame.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5, let url = URL(string: args[1]), let width = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: snap-webkit URL WIDTH light|dark OUT.png\n".utf8))
    exit(64)
}
let dark = args[3] == "dark"
let output = URL(fileURLWithPath: args[4])
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Snapper: NSObject, WKNavigationDelegate {
    let width: CGFloat
    let output: URL
    let view: WKWebView
    let window: NSWindow

    init(width: CGFloat, dark: Bool, output: URL) {
        self.width = width
        self.output = output
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.alphaValue = 0.01
        window.setFrameOrigin(NSPoint(x: 20, y: 20))
        window.orderFrontRegardless()
        view.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let the page-load animation finish, then grow the view to the full page height.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { result, _ in
                let height = (result as? CGFloat) ?? 900
                self.window.setContentSize(NSSize(width: self.width, height: height))
                self.view.frame.size.height = height
                // Give lazy images that are now in view time to load.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    let config = WKSnapshotConfiguration()
                    config.rect = NSRect(x: 0, y: 0, width: self.width, height: height)
                    webView.takeSnapshot(with: config) { image, error in
                        guard let image, let tiff = image.tiffRepresentation,
                              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                            FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                            exit(1)
                        }
                        try? png.write(to: self.output)
                        print(self.output.path)
                        exit(0)
                    }
                }
            }
        }
    }
}

let snapper = Snapper(width: CGFloat(width), dark: dark, output: output)
snapper.view.load(URLRequest(url: url))
app.run()
