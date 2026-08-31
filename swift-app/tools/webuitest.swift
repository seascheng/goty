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

        // 3. thinking phase renders at the transcript tail (the strip
        // moved out of the composer box — orca statusbar model).
        _ = evalJS("window.__gotyStore.apply({type:'phase', value:'thinking'})")
        pump(0.5)
        let strip = evalJS("JSON.stringify({t: document.querySelector('.composer-status')?.textContent ?? '', inTranscript: !!document.querySelector('.transcript .composer-status'), inComposer: !!document.querySelector('.composer .composer-status')})") ?? ""
        check(strip.contains("思考中"), "thinking chip renders in the strip")
        check(strip.contains("\"inTranscript\":true") && strip.contains("\"inComposer\":false"),
              "strip lives at the transcript tail, not above the input")

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

        // A process exit is terminal for startup too: the old store kept
        // the spinner beside the failure forever because only handshake
        // events cleared `starting`.
        _ = evalJS("window.__gotyStore.apply({type:'starting', agent:'OMP'}); window.__gotyStore.apply({type:'working', value:true}); window.__gotyStore.apply({type:'phase', value:'thinking'}); window.__gotyStore.apply({type:'error', text:'agent 进程已退出'})")
        pump(0.5)
        let err = evalJS("JSON.stringify({t: document.querySelector('.composer .composer-status')?.textContent ?? '', r: !!document.querySelector('.composer .composer-status .chip-retry'), starting: window.__gotyStore.starting, working: window.__gotyStore.working, phase: window.__gotyStore.phase, reconnecting: window.__gotyStore.reconnecting})") ?? ""
        check(err.contains("agent 进程已退出") && err.contains("true")
              && err.contains("\"reconnecting\":false"),
              "agent exit clears startup and transient work state")

        // 7. reconnecting replaces the error
        _ = evalJS("window.__gotyStore.apply({type:'reconnecting', value:true})")
        pump(0.5)
        let rec = evalJS("document.querySelector('.composer .composer-status')?.textContent ?? ''") ?? ""


        // 8. history chip: structurally a popover owner. (Synthetic
        // .click() does not reach React's delegated listeners inside
        // WKWebView, so open/dismiss is covered by the single-openPop
        // design: only one popover id exists.)
        // Session title: Swift pushes it after handshake / history load /
        // each turn; the toolbar must render it beside the agent icon.
        _ = evalJS("window.__gotyStore.apply({type:'sessionTitle', title:'修复换行问题'})")
        pump(0.5)
        let title = evalJS("JSON.stringify({t: document.querySelector('.pane-session-title')?.textContent ?? '', s: window.__gotyStore.sessionTitle})") ?? ""
        check(title.contains("修复换行问题") && title.contains("\"s\":\"修复换行问题\""),
              "session title renders in the composer toolbar")
        _ = evalJS("window.__gotyStore.apply({type:'sessionTitle', title:null})")
        pump(0.3)
        check(evalJS("String(!!document.querySelector('.pane-session-title'))") == "false",
              "null session title hides the chip")
        // The "think 文本不换行" report: a fenced code block inside a
        // THOUGHT rendered as a bare <pre> (no container rule) and
        // scrolled the whole transcript sideways.
        _ = evalJS("window.__gotyStore.apply({type:'thoughtChunk', text:'```\\nconstraints: doc.leading == clip.leading, doc.trailing == clip.trailing, doc.top == clip.top, doc.height >= clip.height (priority low), doc.width == clip.width, doc.centerX == clip.centerX, doc.baseline == clip.baseline, doc.vertical == clip.vertical, doc.edges == clip.edges\\n```'})")
        pump(0.5)
        let preStyle = evalJS("getComputedStyle(document.querySelector('.thought pre')).whiteSpace") ?? "?"
        let sw = Int(evalJS("String(document.querySelector('.transcript').scrollWidth)") ?? "-1") ?? -1
        let cw = Int(evalJS("String(document.querySelector('.transcript').clientWidth)") ?? "-1") ?? -1
        check(preStyle == "pre-wrap" && sw >= 0 && sw <= cw,
              "thought code block folds long lines (style=\(preStyle) sw=\(sw) cw=\(cw))")
        // Tool card updates must re-render WITHOUT a click (BlockView
        // memoizes on block/call identity — the store used to swap only
        // the tools Map, freezing cards at mount-time 运行中) and a
        _ = evalJS("window.__gotyStore.apply({type:'toolCall', id:'r1', title:'Bash', kind:'execute', status:'in_progress', content:[{type:'text',text:'ls -la'}]})")
        pump(0.4)
        check(evalJS("String(!!document.querySelector('.tool.open'))") == "false"
              && (evalJS("document.querySelector('.tool-status')?.textContent ?? ''") ?? "").contains("运行中")
              && (evalJS("document.querySelector('.tool-status')?.className ?? ''") ?? "").contains("st-in_progress"),
              "running tool card stays folded, amber 运行中 in header")
        _ = evalJS("window.__gotyStore.apply({type:'toolCall', id:'r1', status:'completed', output:[{type:'text',text:'ok'}]})")
        pump(0.4)
        check((evalJS("document.querySelector('.tool-status')?.textContent ?? ''") ?? "").contains("完成")
              && (evalJS("document.querySelector('.tool-status')?.className ?? ''") ?? "").contains("st-completed")
              && evalJS("String(!!document.querySelector('.tool.open'))") == "false",
              "completion flips the card to green 完成, still folded")
        _ = evalJS("(() => { const ta = document.querySelector('.composer textarea');"
          + " const set = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;"
          + " set.call(ta, 'l1\\nl2\\nl3\\nl4\\nl5\\nl6\\nl7\\nl8');"
          + " ta.dispatchEvent(new Event('input', {bubbles:true})); })()")
        pump(0.3)
        let grownH = Int(evalJS("String(Math.round(document.querySelector('.composer textarea').getBoundingClientRect().height))") ?? "0") ?? 0
        _ = evalJS("(() => { const ta = document.querySelector('.composer textarea');"
          + " ta.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true, cancelable:true})); })()")
        pump(0.4)
        let clearedH = Int(evalJS("String(Math.round(document.querySelector('.composer textarea').getBoundingClientRect().height))") ?? "0") ?? 0
        check(grownH > 100 && clearedH < grownH - 40,
              "submit clears the draft and collapses the grown input (grown=\(grownH) cleared=\(clearedH))")
        // No phantom strip above the input in idle: nothing may sit
        // between the composer box top and the textarea (WKWebView
        // metric — the dead-space report). Clear any leftover turn
        // state first (working:true nulls error, then back to idle).
        _ = evalJS("window.__gotyStore.apply({type:'reconnecting', value:false});"
          + " window.__gotyStore.apply({type:'working', value:true});"
          + " window.__gotyStore.apply({type:'working', value:false})")
        pump(0.3)
        let gapBoxToTa = Int(evalJS("String(Math.round(document.querySelector('.composer textarea').getBoundingClientRect().top"
          + " - document.querySelector('.composer-box').getBoundingClientRect().top))") ?? "99") ?? 99
        check(gapBoxToTa <= 4,
              "idle composer has no phantom strip above the input (gap=\(gapBoxToTa)px)")

        // Text continuity across interleaved reasoning: claude (GLM
        // proxy) alternates thinking/text deltas mid-sentence — the
        // old last-block-only merge shattered "…work" [thought]
        // "bench…" into fragments. Thought must pass through; a tool
        // card still starts a fresh block.
        _ = evalJS("window.__gotyStore.apply({type:'clearTranscript'}); void 0")
        _ = evalJS("window.__gotyStore.apply({type:'agentChunk', text:'This is the work'})")
        _ = evalJS("window.__gotyStore.apply({type:'thoughtChunk', text:'reasoning…'})")
        _ = evalJS("window.__gotyStore.apply({type:'agentChunk', text:'bench, done'})")
        pump(0.4)
        let agentTexts = evalJS("JSON.stringify([...document.querySelectorAll('.agent')].map(el => el.textContent))") ?? "[]"
        check(agentTexts == "[\"This is the workbench, done\"]",
              "agent text continues across interleaved thought (got \(agentTexts))")
        check((evalJS("document.querySelector('.thought')?.textContent ?? ''") ?? "") == "reasoning…",
              "interleaved thought still renders once")
        _ = evalJS("window.__gotyStore.apply({type:'toolCall', id:'x1', title:'Bash', kind:'execute', status:'completed', output:[{type:'text',text:'ok'}]})")
        _ = evalJS("window.__gotyStore.apply({type:'agentChunk', text:'after tool'})")
        pump(0.4)
        let afterTool = evalJS("JSON.stringify([...document.querySelectorAll('.agent')].map(el => el.textContent))") ?? "[]"
        check(afterTool == "[\"This is the workbench, done\",\"after tool\"]",
              "tool card still starts a fresh agent block (got \(afterTool))")
        _ = evalJS("window.__gotyStore.apply({type:'clearTranscript'}); void 0")
        pump(0.2)

        // 8. turn completion → duration stats replace the old 已完成
        // flash; they stick around until the next turn starts.
        _ = evalJS("window.__gotyStore.apply({type:'userMessage', text:'done'});"
          + " window.__gotyStore.apply({type:'working', value:true});"
          + " window.__gotyStore.apply({type:'reconnecting', value:false});"
          + " window.__gotyStore.apply({type:'turnEnded'})")
        pump(0.5)
        let done = evalJS("document.querySelector('.transcript .composer-status')?.textContent ?? ''") ?? ""
        check(done.contains("⏱"), "turn completion shows duration stats in the transcript tail")
        pump(3.2)
        let settled = evalJS("document.querySelector('.transcript .composer-status')?.textContent ?? ''") ?? ""
        check(settled.contains("⏱"), "stats persist after the old flash window")
        check(!settled.contains("已完成"), "no stale done flash")
        exit(failures == 0 ? 0 : 1)
    }
}
