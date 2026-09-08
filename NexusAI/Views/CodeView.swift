import SwiftUI

struct CodeView: View {
    @State private var projectURL: URL?
    @State private var statLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Code workspace")
                .font(.title2.bold())

            Text("Inspect files, explain code, and prepare changes in a local project folder.")
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    openAndInspect()
                } label: {
                    Label(projectURL == nil ? "Open project folder" : "Switch project folder",
                          systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                if projectURL != nil {
                    Button {
                        openAndInspect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }

                if let url = projectURL {
                    Text(url.lastPathComponent)
                        .foregroundStyle(.secondary)
                }
            }

            if statLines.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No project open")
                        .font(.headline)
                    Text("Open a folder to inspect its structure and contents.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(statLines, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: line.hasPrefix("•") ? "circle.fill" : "arrow.right")
                                    .font(.system(size: 6))
                                    .foregroundStyle(.blue)
                                    .padding(.top, 4)
                                Text(line)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
                .frame(minHeight: 200)
                .padding(14)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .cardStyle()
    }

    private func openAndInspect() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url
        inspect(url)
    }

    private func inspect(_ url: URL) {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        let dirs = top.filter { isDirectory(url.appendingPathComponent($0)) }
        let files = top.filter { !isDirectory(url.appendingPathComponent($0)) }
        let swiftFiles = files.filter { $0.hasSuffix(".swift") }.count
        let swiftLines = totalLines(in: url, extensions: ["swift", "m", "mm", "h", "js", "ts", "tsx", "py", "java", "go", "rs", "c", "cpp", "cs"])

        var lines: [String] = []
        lines.append("Project: \(url.lastPathComponent)")
        lines.append("Location: \(url.path)")
        lines.append("Top-level folders: \(dirs.count)")
        lines.append("Top-level files: \(files.count)")
        lines.append("Swift source files: \(swiftFiles)")
        lines.append("Estimated total source lines: \(swiftLines)")
        lines.append("•")
        lines.append("Folders:")
        lines.append(contentsOf: dirs.prefix(20).map { "  📁 \($0)" })
        if dirs.count > 20 {
            lines.append("  … and \(dirs.count - 20) more folders")
        }
        lines.append(contentsOf: ["•", "Files:"])
        lines.append(contentsOf: files.prefix(30).map { "  📄 \($0)" })
        if files.count > 30 {
            lines.append("  … and \(files.count - 30) more files")
        }
        statLines = lines
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func totalLines(in root: URL, extensions: [String]) -> Int {
        let fm = FileManager.default
        var count = 0
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if extensions.contains(where: { fileURL.pathExtension == $0 }) {
                    if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                        count += content.split(whereSeparator: \.isNewline).count
                    }
                }
            }
        }
        return count
    }
}
