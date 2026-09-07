import Foundation

/// A typed chat command (`/name ...`) recognised before the normal LLM
/// exchange. Commands translate to deterministic, well-typed actions.
struct ChatCommand: Equatable, Sendable {
    enum Name: String, CaseIterable, Codable, Sendable {
        case help
        case research
        case deep
        case remember
        case compute
        case eval
        case clear

        var usage: String {
            switch self {
            case .help: return "/help"
            case .research: return "/research <query>"
            case .deep: return "/deep <query>"
            case .remember: return "/remember <fact>"
            case .compute: return "/compute <expression>"
            case .eval: return "/eval"
            case .clear: return "/clear"
            }
        }

        var summary: String {
            switch self {
            case .help: return "List available commands"
            case .research: return "Grounded web research with sources"
            case .deep: return "Deep, multi-step research"
            case .remember: return "Store a fact in long-term memory"
            case .compute: return "Evaluate a safe arithmetic expression"
            case .eval: return "Run the golden eval suite locally"
            case .clear: return "Clear the current session"
            }
        }
    }

    let name: Name
    let args: [String]
}

enum ChatCommandAction: Equatable, Sendable {
    case help
    case research(query: String)
    case deepResearch(query: String)
    case remember(fact: String)
    case compute(expression: String)
    case eval
    case clear
}

enum ChatCommandParse: Equatable, Sendable {
    case notACommand
    case action(ChatCommandAction)
    case usageError(message: String)
}

enum ChatCommandParser {
    static func parse(_ input: String) -> ChatCommandParse {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .notACommand }
        let body = trimmed.dropFirst()
        guard let raw = body.split(separator: " ", maxSplits: 1).first.map(String.init),
              !raw.isEmpty else {
            return .usageError(message: helpText)
        }
        guard let name = ChatCommand.Name(rawValue: raw.lowercased()) else {
            return .usageError(message: "Unknown command “/\(raw)”. Send /help to list available commands.")
        }
        let parts = body.split(separator: " ", maxSplits: 1)
        let args = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
        switch name {
        case .help, .clear, .eval:
            guard args.isEmpty else {
                return .usageError(message: "\(name.usage) takes no arguments.")
            }
            return .action(action(for: name))
        case .research, .deep, .remember, .compute:
            guard !args.isEmpty else {
                return .usageError(message: usageHint(for: name))
            }
            switch name {
            case .research: return .action(.research(query: args.joined(separator: " ")))
            case .deep: return .action(.deepResearch(query: args.joined(separator: " ")))
            case .remember: return .action(.remember(fact: args.joined(separator: " ")))
            case .compute: return .action(.compute(expression: args.joined(separator: " ")))
            default: return .usageError(message: usageHint(for: name))
            }
        }
    }

    private static func action(for name: ChatCommand.Name) -> ChatCommandAction {
        switch name {
        case .help: return .help
        case .clear: return .clear
        case .eval: return .eval
        default: return .help
        }
    }

    private static func usageHint(for name: ChatCommand.Name) -> String {
        "Use \(name.usage) — e.g. \(example(for: name))"
    }

    private static func example(for name: ChatCommand.Name) -> String {
        switch name {
        case .research: return "/research iPhone 18 battery life"
        case .deep: return "/deep Apple Watch activity rings"
        case .remember: return "/remember my WiFi is called Nebula"
        case .compute: return "/compute (4 + 6) * 3"
        default: return name.usage
        }
    }

    static var helpText: String {
        var lines = ["Available commands (send one to run it):", ""]
        for name in ChatCommand.Name.allCases {
            lines.append("\(name.usage)  —  \(name.summary)")
        }
        lines.append("")
        lines.append("Typed commands bypass the model and run the app's own")
        lines.append("tools, so they work even while the local model is offline.")
        return lines.joined(separator: "\n")
    }
}

/// Safe arithmetic evaluator used by `/compute`. Supports `+ - * /`,
/// parentheses, unary plus/minus, and decimals; everything else is rejected.
enum ExpressionEvaluator {
    private struct Parsers {
        let chars: [Character]
        var i = 0

        var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func advance() { i += 1 }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while let c = peek {
                if c == "+" {
                    advance()
                    guard let rhs = parseTerm() else { return nil }
                    value += rhs
                } else if c == "-" {
                    advance()
                    guard let rhs = parseTerm() else { return nil }
                    value -= rhs
                } else {
                    break
                }
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while let c = peek {
                if c == "*" {
                    advance()
                    guard let rhs = parseFactor() else { return nil }
                    value *= rhs
                } else if c == "/" {
                    advance()
                    guard let rhs = parseFactor() else { return nil }
                    guard rhs != 0 else { return nil }
                    value /= rhs
                } else {
                    break
                }
            }
            return value
        }

        mutating func parseFactor() -> Double? {
            if peek == "(" {
                advance()
                guard let value = parseExpression(), peek == ")" else { return nil }
                advance()
                return value
            }
            if peek == "-" {
                advance()
                guard let value = parseFactor() else { return nil }
                return -value
            }
            if peek == "+" {
                advance()
                return parseFactor()
            }
            return parseNumber()
        }

        mutating func parseNumber() -> Double? {
            var digits = ""
            var sawDot = false
            while let c = peek {
                if c.isNumber {
                    digits.append(c)
                    advance()
                } else if c == ".", !sawDot {
                    sawDot = true
                    digits.append(c)
                    advance()
                } else {
                    break
                }
            }
            guard !digits.isEmpty else { return nil }
            return Double(digits)
        }
    }

    /// Returns the value of a safe arithmetic expression, or nil if it can't
    /// be parsed (letters, unbalanced parentheses, division by zero…).
    static func evaluate(_ expression: String) -> Double? {
        let chars = Array(expression.filter { !$0.isWhitespace })
        guard !chars.isEmpty else { return nil }
        var parser = Parsers(chars: chars)
        guard let value = parser.parseExpression(), parser.i == parser.chars.count else {
            return nil
        }
        return value
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.6g", value)
    }
}