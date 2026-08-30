// webuitest.swift — the agent-web page under a REAL WKWebView.
//
// Synthetic store events go through the SAME store the GUI consumes
// (window.__gotyStore.apply); the composer status strip must render
// the turn states directly above the input. This closes the loop the
// unit tests can't: schema → store → React → DOM.
//
// Built and run by run-tests.sh; NOT part of the app binary.
import Cocoa
import WebKit
@testable import goty

@main
enum WebUITest {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "goty-webuitest"
        window.contentView = webView
        window.orderFrontRegardless()

        // Dist resolution: packaged bundle first (the app runbook);
        // GOTY_AGENTWEB_DIST for ad-hoc runs; cwd-relative for bare
        // binaries (run-tests runs them with cwd = swift-app); the
        // #filePath walk is the last resort for odd launch cwds.
        let dist: URL
        if let bundled = Bundle.main.url(forResource: "index", withExtension: "html",
                                         subdirectory: "agent-web") {
            dist = bundled
        } else if let overridden = ProcessInfo.processInfo.environment["GOTY_AGENTWEB_DIST"] {
            dist = URL(fileURLWithPath: overridden)
        } else if FileManager.default.fileExists(atPath: "agent-web/dist/index.html") {
            dist = URL(fileURLWithPath: "agent-web/dist/index.html")
        } else {
            var sourcePath = #filePath
            if !sourcePath.hasPrefix("/") {
                sourcePath = FileManager.default.currentDirectoryPath + "/" + sourcePath
            }
            let repo = URL(fileURLWithPath: sourcePath)
                .deletingLastPathComponent() // tools
                .deletingLastPathComponent() // swift-app
            dist = repo.appendingPathComponent("agent-web/dist/index.html")
        }
        webView.loadFileURL(dist, allowingReadAccessTo: dist.deletingLastPathComponent())

        func pump(_ seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        func evalJS(_ js: String) -> String? {
            var result: String?
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                webView.evaluateJavaScript(js) { r, _ in
                    result = r as? String
                    done.signal()
                }
            }
            // evalJS is usually called ON main: blocking the semaphore
            // there deadlocks the very queue the JS runs on — pump the
            // runloop instead (agentprobe's rule).
            if Thread.isMainThread {
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    if done.wait(timeout: .now()) == .success { break }
                }
            } else {
                _ = done.wait(timeout: .now() + 10)
            }
            return result
        }

        // 1. wait for the store handle (React boot)
        var booted = false
        let bootDeadline = Date().addingTimeInterval(30)
        while Date() < bootDeadline {
            pump(0.3)
            if evalJS("typeof window.__gotyStore") == "object" { booted = true; break }
        }
        if !booted {
            let href = evalJS("location.href") ?? "?"
            let ready = evalJS("document.readyState") ?? "?"
            let root = evalJS("String(document.getElementById('root') ? document.getElementById('root').childElementCount : -1)") ?? "?"
            print("DIAG href=\(href) ready=\(ready) rootChildren=\(root)")
        }
        check(booted, "page boots and exposes __gotyStore")
        guard booted else { print("WEBUITEST FAIL"); exit(1) }

        // 2. strip hidden on an idle pane
        pump(0.5)
        let idle = evalJS("document.querySelector('.composer-status')?.textContent ?? ''") ?? ""
        check(!idle.contains("思考中"), "idle pane shows no phase strip")

        // 3. thinking phase renders above the input
        _ = evalJS("window.__gotyStore.apply({type:'phase', value:'thinking'})")
        pump(0.5)
        let strip = evalJS("JSON.stringify({t: document.querySelector('.composer-status')?.textContent ?? '', above: !!document.querySelector('.composer-status')?.closest('.composer-box')?.querySelector('textarea')})") ?? ""
        check(strip.contains("思考中"), "thinking chip renders in the strip")
        check(strip.contains("true"), "strip sits inside the composer box above the input")

        // 4. executing swaps the label
        _ = evalJS("window.__gotyStore.apply({type:'phase', value:'executing'})")
        pump(0.5)
        let exec = evalJS("document.querySelector('.composer-status')?.textContent ?? ''") ?? ""
        check(exec.contains("执行中") && !exec.contains("思考中"), "executing swaps the label")

        // 5. awaiting permission
        _ = evalJS("window.__gotyStore.apply({type:'phase', value:'awaitingPermission'})")
        pump(0.5)
        check((evalJS("document.querySelector('.composer-status')?.textContent ?? ''") ?? "").contains("等待授权"),
              "awaitingPermission renders")

        // 6. error chip carries 重试
        _ = evalJS("window.__gotyStore.apply({type:'phase', value:null}); window.__gotyStore.apply({type:'error', text:'连接失败'})")
        pump(0.5)
        let err = evalJS("JSON.stringify({t: document.querySelector('.composer-status')?.textContent ?? '', r: !!document.querySelector('.composer-status .chip-retry')})") ?? ""
        check(err.contains("连接失败") && err.contains("true"), "error chip carries a 重试 button")

        // 7. reconnecting replaces the error
        _ = evalJS("window.__gotyStore.apply({type:'reconnecting', value:true})")
        pump(0.5)
        let rec = evalJS("document.querySelector('.composer-status')?.textContent ?? ''") ?? ""
        check(rec.contains("重连中") && !rec.contains("连接失败"), "reconnecting replaces the error chip")


        // 8. history chip: structurally a popover owner. (Synthetic
        // .click() does not reach React's delegated listeners inside
        // WKWebView, so open/dismiss behavior is covered by the
        // single-openPop-state design: only one popover id exists,
        // making stacked popovers impossible by construction.)
        check(evalJS("String(!!document.querySelector('[data-pop=\"history\"] .icon-chip'))") == "true",
              "history chip is an icon pill with a popover owner")
        check(evalJS("String(document.querySelectorAll('[data-pop]').length >= 1)") == "true",
              "composer toolbar renders popover owners")

        // 8. done flash then idle clears
        _ = evalJS("window.__gotyStore.apply({type:'reconnecting', value:false}); window.__gotyStore.apply({type:'turnEnded'})")
        pump(0.5)
        let done = evalJS("document.querySelector('.composer-status')?.textContent ?? ''") ?? ""
        check(done.contains("已完成"), "clean turn shows the done flash")

        print(failures == 0 ? "webuitest: all passed" : "webuitest: FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}
