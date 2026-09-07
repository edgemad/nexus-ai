import Foundation

/// Verifies Phase 7 typed read-only tools: JSON validation (absolute paths, no
/// traversal, required fields), native directory listing, capped file reads,
/// and depth/hidden-rule file search. All against temp fixtures, no shell.
@main
struct ToolsHarness {
    static var failures = 0

    static func fail(_ msg: String) {
        print("FAIL \(msg)")
        failures += 1
    }
    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("PASS \(msg)") } else { fail(msg) }
    }

    static func main() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-harness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.path

        // Fixtures.
        let aTxt = root.appendingPathComponent("alpha.txt")
        let bMd = root.appendingPathComponent("beta.md")
        let hidden = root.appendingPathComponent(".hidden.log")
        let sub = root.appendingPathComponent("sub")
        let subX = sub.appendingPathComponent("zeta.txt")
        let big = root.appendingPathComponent("big.txt")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try! "Hello from alpha, line one.\n".write(to: aTxt, atomically: true, encoding: .utf8)
        try! "# Beta doc\n".write(to: bMd, atomically: true, encoding: .utf8)
        try! "secret".write(to: hidden, atomically: true, encoding: .utf8)
        try! "zeta contents".write(to: subX, atomically: true, encoding: .utf8)
        try! String(repeating: "b", count: 4096).write(to: big, atomically: true, encoding: .utf8)

        // --- Validation ---
        let badTool = ReadOnlyTools.validate(["path": "/\(base)"])
        check(ifFailure(badTool), "validation rejects missing tool")

        let relPath = ReadOnlyTools.validate(["tool": "read_file", "path": "relative.txt"])
        check(ifFailure(relPath), "validation rejects relative path")

        let traversal = ReadOnlyTools.validate(["tool": "list_directory", "path": "/Users/me/../etc"])
        check(ifFailure(traversal), "validation rejects .. traversal")

        let emptyQuery = ReadOnlyTools.validate(["tool": "search_files", "path": base, "query": "  "])
        check(ifFailure(emptyQuery), "validation rejects empty query")

        let missing = ReadOnlyTools.validate(["tool": "read_file", "path": "\(base)/nope.txt"])
        check(match(missing, .fileNotFound), "validation rejects missing file")

        let dirAsFile = ReadOnlyTools.validate(["tool": "read_file", "path": sub.path])
        check(ifFailure(dirAsFile), "validation rejects reading a directory")

        // --- list_directory ---
        if case .success(let call) = ReadOnlyTools.validate(["tool": "list_directory", "path": base]) {
            let result = ReadOnlyTools.run(call)
            check(!result.failed, "list_directory succeeds")
            check(result.text.contains("alpha.txt"), "list shows alpha.txt")
            check(result.text.contains("sub"), "list shows sub directory")
            check(!result.text.contains("zeta.txt"), "list is not recursive")
        } else { fail("list_directory validation") }

        // --- read_file ---
        if case .success(let call) = ReadOnlyTools.validate(["tool": "read_file", "path": aTxt.path]) {
            let result = ReadOnlyTools.run(call)
            check(!result.failed && result.text.contains("Hello from alpha"), "read_file returns UTF-8 text")
        } else { fail("read_file validation") }

        if case .success(let call) = ReadOnlyTools.validate(["tool": "read_file", "path": big.path, "maxBytes": 1000]) {
            let result = ReadOnlyTools.run(call)
            check(result.failed && result.text.contains("over the 1000-byte cap"),
                  "read_file aborts reads over the byte cap")
        } else { fail("read_file maxBytes validation") }

        // --- search_files ---
        if case .success(let call) = ReadOnlyTools.validate(["tool": "search_files", "path": base, "query": "txt"]) {
            let result = ReadOnlyTools.run(call)
            check(!result.failed, "search_files succeeds")
            check(result.text.contains("alpha.txt") && result.text.contains("zeta.txt"),
                  "search matches nested + top-level names")
            check(!result.text.contains(".hidden"), "search skips hidden by default")
        } else { fail("search_files validation") }

        if case .success(let call) = ReadOnlyTools.validate(["tool": "search_files", "path": base,
                                                             "query": "log", "includeHidden": true]) {
            let result = ReadOnlyTools.run(call)
            check(result.text.contains(".hidden.log"), "search includes hidden when requested")
        } else { fail("search_files hidden option") }

        try? FileManager.default.removeItem(at: root)

        if failures == 0 {
            print("ALL TOOLS CHECKS PASSED")
        } else {
            print("\(failures) TOOLS CHECK(S) FAILED")
            exit(1)
        }
    }

    static func ifFailure<T>(_ r: Result<T, NexusError>) -> Bool {
        if case .failure = r { return true }
        return false
    }
    static func match<T>(_ r: Result<T, NexusError>, _ code: NexusErrorCode) -> Bool {
        if case .failure(let e) = r { return e.code == code }
        return false
    }
}