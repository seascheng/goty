// Files-tab behavior tests (headless): the context-menu creation flow
// must leave a LIVING inline row, and a committed name must create the
// real file. Two rounds of "New File/New Folder 闪一下就没了" came from
// focus-churn kills; this is the contract that stops a third.
import AppKit
@testable import goty

/// Minimal KeyedRow stand-in for container-layout tests.
final class FilesTestRow: NSView, KeyedRow {
    let rowKey: String
    init(_ key: String) {
        self.rowKey = key
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }
}
enum FilesTest {
    static func run() {
        setenv("GOTY_HEADLESS", "1", 1)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = content
        let files = FilesView()
        files.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(files)
        NSLayoutConstraint.activate([
            files.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            files.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            files.topAnchor.constraint(equalTo: content.topAnchor),
            files.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        // The repo's own tree (needs a real Sources/ directory). Derived
        // from #filePath so the suite follows the project when it moves —
        // a project rename once broke the hardcoded absolute path.
        // #filePath is whatever path form swiftc received — relative
        // when run-tests.sh compiles from swift-app/ ("tools/filestest.swift")
        // — which made root "" and every assertion below fail with the
        // tree never loading (the 6 "pre-existing" failures; the app
        // itself was fine). Complete a relative form with the process
        // cwd, which run-tests.sh keeps at swift-app/.
        var sourcePath = #filePath
        if !sourcePath.hasPrefix("/") {
            sourcePath = FileManager.default.currentDirectoryPath + "/" + sourcePath
        }
        let root = ((sourcePath as NSString).deletingLastPathComponent
            as NSString).deletingLastPathComponent   // tools/ → swift-app/
        files.setDirectory(root, source: LocalFileSource())
        for _ in 0..<20 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        var failures = 0
        func check(_ cond: Bool, _ name: String) {
            if cond { print("  ok  \(name)") } else { failures += 1; print("FAIL  \(name)") }
        }

        // The menu itself, built exactly as a right-click builds it.
        let entry = FileEntry(name: "Sources", isDirectory: true)
        let menu = files.rowMenu(for: entry, path: root + "/Sources")
        check(menu.items.count >= 6, "row menu has the verbs")
        check(menu.items[0].title.hasPrefix("New File"), "first verb is New File")

        // Fire "New File…" exactly as NSMenu would. The row must still
        // exist after the runloop settles — no input, no clicks.
        let item = menu.items[0]
        _ = item.target?.perform(item.action!, with: item)
        var alive = true
        for _ in 0..<24 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if files.currentCreationRow == nil { alive = false }
        }
        check(alive, "creation row survives focus churn (no spurious commit)")

        // A typed name commits into a real file.
        files.currentCreationRow?.typeForTest("zzz-test-create.swift")
        files.currentCreationRow?.commitForTest()
        for _ in 0..<20 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let made = FileManager.default.fileExists(atPath: root + "/Sources/zzz-test-create.swift")
        check(made, "committed name creates the file")
        try? FileManager.default.removeItem(atPath: root + "/Sources/zzz-test-create.swift")

        // Rename: inline row prefilled with the old name; a commit
        // renames on disk (tty7 TreeEdit::Rename semantics).
        // Rename a THROWAWAY direct child of the expanded Sources dir —
        // product files stay untouched.
        FileManager.default.createFile(
            atPath: root + "/Sources/zzz-rename-me.swift", contents: Data())
        for entryDir in ["/Sources"] {
            files.refreshDirForTest(dir: root + entryDir)
        }
        for _ in 0..<8 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        files.beginRenameForTest(path: root + "/Sources/zzz-rename-me.swift")
        check(files.currentRenameText == "zzz-rename-me.swift",
              "rename row prefilled with the current name")
        // A spurious resign (menu teardown / responder restore steal)
        // must NOT resolve an unedited row — the instant-revert bug.
        files.currentCreationRow?.simulateSpuriousResignForTest()
        check(files.currentRenameText != nil,
              "unedited rename survives a focus steal")
        // Hold the row instance: a listing refresh can rebuild rows
        // between typing and committing, and a commit on a stale row
        // sends the prefilled old name (a silent no-op).
        let renameRow = files.currentCreationRow
        renameRow?.typeForTest("zzz-renamed.swift")
        renameRow?.commitForTest()
        for _ in 0..<20 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let renamed = FileManager.default.fileExists(atPath: root + "/Sources/zzz-renamed.swift")
        check(renamed, "rename commits to disk")
        // Move API round trip (restore), then clean up.
        files.moveForTest(from: root + "/Sources/zzz-renamed.swift",
                          to: root + "/Sources/zzz-moved.swift")
        for _ in 0..<8 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(FileManager.default.fileExists(atPath: root + "/Sources/zzz-moved.swift"),
              "move API relocates")
        try? FileManager.default.removeItem(atPath: root + "/Sources/zzz-moved.swift")

        // tree-sitter engine: real grammars color real code (queries
        // ride along in /tmp/ts-queries for the bare test binary).
        let swiftCode = "func greet(name: String) -> Int { return 1 }"
        let colored = HighlightEngine.highlight(swiftCode, language: "swift",
                                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                                color: .white)
        var colors = Set<NSColor>()
        colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) { v, _, _ in
            if let c = v as? NSColor { colors.insert(c) }
        }
        check(colors.count > 2,
              "tree-sitter colors swift code (\(colors.count) colors)")
        let unknown = HighlightEngine.highlight("plain", language: nil,
                                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                                color: .white)
        check(unknown.length == 5, "unknown language renders plain")
        // FileListContainer: a height change mid-expand must not re-lay
        // rows in subview z-order — expanded children used to drop
        // below every older row once the document grew past the clip
        // view (the "subtree appears at the bottom" bug).
        let clipHost = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        let list = FileListContainer(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        clipHost.addSubview(list)
        func keyRows(_ keys: [String]) -> [(key: String, view: NSView)] {
            keys.map { (key: $0, view: FilesTestRow($0)) }
        }
        func frameByRow() -> [String: CGFloat] {
            var frames: [String: CGFloat] = [:]
            for row in list.subviews {
                if let keyed = row as? KeyedRow { frames[keyed.rowKey] = row.frame.minY }
            }
            return frames
        }
        list.setRows(keyRows(["a", "b"]))
        list.setRows(keyRows(["a", "a1", "a2", "a3", "b"]))   // 5 × 26 > 52
        let grown = frameByRow()
        check(grown["a"] == 0 && grown["a1"] == 26 && grown["a2"] == 52
              && grown["a3"] == 78 && grown["b"] == 104,
              "expanded children stay directly under their folder")
        list.setRows(keyRows(["a", "b"]))   // collapse shrinks the document
        let collapsed = frameByRow()
        check(collapsed["a"] == 0 && collapsed["b"] == 26, "collapse re-orders too")


        // Themed dialog semantics via the presenter seam (headless
        // has no key window for Return/Esc routing; visuals are
        // verified on the live app).
        Dialog.presenterOverride = { kind, _ in
            if kind == "prompt" { return "valid-name.swift" }  // prompt answers
            return "yes"                                        // confirm answers
        }
        check(Dialog.confirm(title: "t", detail: "d", action: "Go"), "confirm answers primary")
        check(Dialog.prompt(title: "t", placeholder: "p") == "valid-name.swift",
              "prompt returns the entered text")
        Dialog.error(title: "t", detail: "d")   // must simply return
        Dialog.presenterOverride = { _, _ in nil }
        check(Dialog.confirm(title: "t", detail: "d", action: "Go") == false,
              "cancel answers false")
        check(Dialog.prompt(title: "t", placeholder: "p") == nil, "cancel answers nil")
        Dialog.presenterOverride = nil

        // TreeOps (Core, pure): the move rules without a view.
        if case .success(let p) = TreeOps.planMove(paths: ["/s/new.txt"], into: "/r",
                                                   existing: [FileEntry(name: "taken.txt", isDirectory: false)]) {
            check(p.moves.first?.to == "/r/new.txt", "plan builds the move")
            check(p.conflicts.isEmpty, "fresh name has no conflict")
        } else { check(false, "plan builds the move") }
        if case .success(let p2) = TreeOps.planMove(paths: ["/s/taken.txt"], into: "/r",
                                                    existing: [FileEntry(name: "taken.txt", isDirectory: false)]) {
            check(p2.conflicts == ["taken.txt"], "conflict name reported")
        } else { check(false, "conflict name reported") }
        if case .success = TreeOps.planMove(paths: ["/r"], into: "/r/sub", existing: nil) {
            check(false, "into-itself refused")
        } else { check(true, "into-itself refused") }
        if case .success = TreeOps.planMove(paths: ["/r/a.txt"], into: "/r", existing: nil) {
            check(false, "same-dir refused")
        } else { check(true, "same-dir refused") }
        let rekeyed = TreeOps.rekeyedExpanded(["/r/d", "/r/d/x", "/r/other"],
                                              from: "/r/d", to: "/r/e")
        check(rekeyed == ["/r/e", "/r/e/x", "/r/other"], "expanded keys move with the dir")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
        exit(failures == 0 ? 0 : 1)
    }
}


@main
enum FilesTestMain {
    static func main() { FilesTest.run() }
}
