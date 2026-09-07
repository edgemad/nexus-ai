import Foundation

/// A computer-control action the model can propose (run a command, open a
/// file/link, reveal in Finder, list a folder). Every action must be approved
/// by the user before it executes.
enum AgentActionKind: String, Codable {
    case runCommand = "run_command"
    case openFile = "open_file"
    case revealFile = "reveal_file"
    case openURL = "open_url"
    case listFiles = "list_files"
    case readFile = "read_file"
    case searchFiles = "search_files"
    case upgrade = "upgrade"

    var title: String {
        switch self {
        case .runCommand: return "Run command in terminal"
        case .openFile: return "Open file"
        case .revealFile: return "Reveal in Finder"
        case .openURL: return "Open web page"
        case .listFiles: return "List directory"
        case .readFile: return "Read file"
        case .searchFiles: return "Search files"
        case .upgrade: return "Propose system upgrade"
        }
    }

    var icon: String {
        switch self {
        case .runCommand: return "terminal"
        case .openFile: return "doc.on.doc"
        case .revealFile: return "magnifyingglass"
        case .openURL: return "globe"
        case .listFiles: return "folder"
        case .readFile: return "doc.text"
        case .searchFiles: return "magnifyingglass.circle"
        case .upgrade: return "wand.and.stars"
        }
    }
}

/// A proposed computer-control action. Durable: the executor persists the
/// whole array (id, approval link, status) so pending and approved actions,
/// and the approvals attached to them, survive an app relaunch.
struct AgentAction: Identifiable, Codable {
    var id = UUID()
    let kind: AgentActionKind
    let command: String
    let fromMessageID: UUID
    var approvalID: UUID?
    var result: String?
    var status: Status

    enum Status: String, Codable {
        case pending, approved, running, done, failed, denied, cancelled

        var label: String {
            switch self {
            case .pending: return "Waiting for your approval"
            case .approved: return "Approved"
            case .running: return "Running…"
            case .done: return "Completed"
            case .failed: return "Failed"
            case .denied: return "Denied"
            case .cancelled: return "Cancelled"
            }
        }
    }
}