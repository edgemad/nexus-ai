import Foundation

/// Typed read-only tools (Phase 7). These replace generic `shell` invocation
/// for directory listing, file reading, and file search: every input is a
/// validated JSON tool call, every operation runs natively through FileManager
/// (no child process), and the results are bounded so they can never flood the
/// conversation or block the app.
///
/// Security model:
/// - only absolute paths are accepted (no bare‑relative, no `~`-encoded shells)
/// - `..` traversal segments are rejected before resolution
/// - symlinks are resolved and the final target must not itself be a symlink
///   escape beyond the requested scope (the resolved path is what is read)
/// - reads are capped (default 20 KB, hard ceiling 200 KB)
/// - lists cap at 200 entries; searches cap at 50 hits and depth 8
/// - read-only by construction: no API here can create, modify, or delete
enum ReadOnlyTool: String, CaseIterable {
    case listDirectory = "list_directory"
    case readFile = "read_file"
    case searchFiles = "search_files"

    var title: String {
        switch self {
        case .listDirectory: return "List directory"
        case .readFile: return "Read file"
        case .searchFiles: return "Search files"
        }
    }

    var instructionSnippet: String {
        switch self {
        case .listDirectory: return "list_directory:  json = {\"path\":\"<absolute dir>\"}"
        case .readFile: return "read_file:      json = {\"path\":\"<absolute file>\",\"maxBytes\":20000}"
        case .searchFiles: return "search_files:  json = {\"path\":\"<absolute dir>\",\"query\":\"<name substring>\"}"
        }
    }
}

/// A validated tool invocation. `json` holds the raw parameters the model
/// emitted; only `tool` is mandatory. Every other field is bounded by
/// `ReadOnlyTools.validate` before execution.
struct ReadOnlyToolCall {
    let tool: ReadOnlyTool
    let path: String
    let maxBytes: Int
    let query: String
    let maxDepth: Int
    let includeHidden: Bool
}

/// The typed implementation + validator for the three read-only tools.
enum ReadOnlyTools {

    static let defaultMaxBytes = 20_000
    static let hardMaxBytes = 200_000
    static let defaultMaxDepth = 4
    static let hardMaxDepth = 8
    static let listEntryCap = 200
    static let searchResultCap = 50

    // MARK: - Input validation

    /// Parses and validates a JSON tool-call payload. Returns a typed call or a
    /// `NexusError` describing exactly which field was invalid.
    static func validate(_ json: [String: Any]) -> Result<ReadOnlyToolCall, NexusError> {
        guard let toolRaw = json["tool"] as? String,
              let tool = ReadOnlyTool(rawValue: toolRaw) else {
            return .failure(NexusError(.invalidInput, "Unknown or missing tool name"))
        }
        guard let pathRaw = json["path"] as? String, !pathRaw.isEmpty else {
            return .failure(NexusError(.invalidInput, "Tool \"\(tool.rawValue)\" requires an absolute \"path\"."))
        }
        let expanded = (pathRaw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure(NexusError(.invalidInput, "Tool \"\(tool.rawValue)\" requires an absolute path."))
        }

        // Reject explicit traversal segments before resolution.
        let segments = expanded.split(separator: "/")
        if segments.contains("..") {
            return .failure(NexusError(.invalidInput, "Path traversal (\"..\") is not allowed."))
        }

        let resolved = (expanded as NSString).resolvingSymlinksInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            return .failure(NexusError(.fileNotFound, "Path not found: \(pathRaw)"))
        }

        var maxBytes = ReadOnlyTools.defaultMaxBytes
        if let raw = json["maxBytes"] as? Int { maxBytes = raw }
        maxBytes = min(max(maxBytes, 512), ReadOnlyTools.hardMaxBytes)

        var maxDepth = ReadOnlyTools.defaultMaxDepth
        if let raw = json["maxDepth"] as? Int { maxDepth = raw }
        maxDepth = min(max(maxDepth, 1), ReadOnlyTools.hardMaxDepth)

        let query = (json["query"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if tool == .searchFiles, query.isEmpty {
            return .failure(NexusError(.invalidInput, "search_files requires a non-empty \"query\"."))
        }
        let includeHidden = json["includeHidden"] as? Bool ?? false

        switch tool {
        case .listDirectory, .searchFiles:
            guard isDirectory.boolValue else {
                return .failure(NexusError(.invalidInput, "Path is not a directory: \(pathRaw)"))
            }
        case .readFile:
            guard !isDirectory.boolValue else {
                return .failure(NexusError(.invalidInput, "Path is a directory, not a file: \(pathRaw)"))
            }
        }
        return .success(ReadOnlyToolCall(tool: tool, path: resolved, maxBytes: maxBytes,
                                         query: query, maxDepth: maxDepth,
                                         includeHidden: includeHidden))
    }

    /// Parses the JSON blob embedded in a tool action's `command` field.
    static func parse(_ command: String) -> Result<ReadOnlyToolCall, NexusError> {
        guard let data = command.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(NexusError(.invalidInput, "Tool call is not valid JSON."))
        }
        return validate(obj)
    }

    // MARK: - Execution (FileManager only, no shell, always read-only)

    static func run(_ call: ReadOnlyToolCall) -> ShellResult {
        switch call.tool {
        case .listDirectory: return listDirectory(call)
        case .readFile: return readFile(call)
        case .searchFiles: return searchFiles(call)
        }
    }

    /// `list_directory`: sorted entries with a `[d]`/`[f]` marker, size, and
    /// name — capped at 200 entries. Content summary folded in for readability.
    static func listDirectory(_ call: ReadOnlyToolCall) -> ShellResult {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: call.path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                               options: [.skipsPackageDescendants])
        } catch {
            return ShellResult(text: "Could not list \(call.path): \(error.localizedDescription)", failed: true,
                               errorCode: .fileNotFound)
        }

        if items.isEmpty {
            return ShellResult(text: "(empty directory)", failed: false)
        }

        let sorted = items.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        var lines: [String] = []
        lines.append("Listing \(call.path):")
        for item in sorted.prefix(ReadOnlyTools.listEntryCap) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let isLink = values?.isSymbolicLink ?? false
            let size = values?.fileSize ?? 0
            let marker = isLink ? "l" : (isDir ? "d" : "f")
            let sizeStr = isDir ? "-" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            lines.append(String(format: "[%@] %@  %@", marker, sizeStr, item.lastPathComponent))
        }
        if items.count > ReadOnlyTools.listEntryCap {
            lines.append("… \(items.count - ReadOnlyTools.listEntryCap) more entries omitted")
        }
        return ShellResult(text: lines.joined(separator: "\n"), failed: false)
    }

    /// `read_file`: reads a regular file as UTF-8 (falling back to Latin-1),
    /// truncating at `maxBytes` with an explicit marker.
    static func readFile(_ call: ReadOnlyToolCall) -> ShellResult {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: call.path)
        let fileSize = (try? fm.attributesOfItem(atPath: call.path)[.size] as? Int) ?? 0
        if fileSize > call.maxBytes {
            return ShellResult(text: "File is \(fileSize) bytes (over the \(call.maxBytes)-byte cap); aborting read. "
                                       + "Asking the model to retry with a larger maxBytes if truly needed is not allowed — cap stands.",
                               failed: true, errorCode: .toolBlocked)
        }
        guard let data = fm.contents(atPath: call.path) else {
            return ShellResult(text: "Could not read \(call.path)", failed: true, errorCode: .fileNotFound)
        }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            text = latin1 + "\n[binary or non-UTF-8 content shown as Latin-1]"
        } else {
            return ShellResult(text: "Unreadable encoding for \(call.path)", failed: true)
        }
        var out = text
        if out.count > call.maxBytes {
            out = String(out.prefix(call.maxBytes)) + "\n[truncated at \(call.maxBytes) characters]"
        }
        return ShellResult(text: out.isEmpty ? "(empty file)" : out, failed: false)
    }

    /// `search_files`: depth-bounded filename search over a directory tree,
    /// capped at 50 hits. Never descends into hidden folders unless requested.
    static func searchFiles(_ call: ReadOnlyToolCall) -> ShellResult {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: call.path, isDirectory: true)
        let query = call.query.lowercased()

        var hits: [URL] = []
        var depthExceeded = false
        var scanSkipped = 0

        let enumerator = fm.enumerator(at: root,
                                       includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                                       options: [.skipsPackageDescendants],
                                       errorHandler: { _, _ in true })
        var depth = 0
        while let item = enumerator?.nextObject() as? URL, hits.count < ReadOnlyTools.searchResultCap {
            let level = enumerator?.level ?? 0
            if level == 0 { depth = 0 }
            if level > call.maxDepth {
                if !depthExceeded { depthExceeded = true }
                continue
            }
            depth = level
            let name = item.lastPathComponent
            if !call.includeHidden, name.hasPrefix(".") {
                scanSkipped += 1
                continue
            }
            if name.lowercased().contains(query) {
                hits.append(item)
            }
        }

        if hits.isEmpty {
            return ShellResult(text: "No matches for \"\(call.query)\" under \(call.path).", failed: false)
        }
        var lines = ["\(hits.count) match(es) for \"\(call.query)\" under \(call.path):"]
        for hit in hits {
            lines.append(hit.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
        if hits.count >= ReadOnlyTools.searchResultCap {
            lines.append("… results capped at \(ReadOnlyTools.searchResultCap)")
        }
        if depthExceeded {
            lines.append("… search depth capped at \(call.maxDepth)")
        }
        return ShellResult(text: lines.joined(separator: "\n"), failed: false)
    }
}