import Foundation

// Phase 11: typed chat commands. Parser, arg validation, usage errors, and
// the safe arithmetic evaluator are deterministic and tested here.

var failures = 0

@main
struct CommandHarness {
    static func main() {
        check(ChatCommandParser.parse("hello world") == .notACommand,
              "plain message is not a command")
        check(ChatCommandParser.parse("  /help  ") == .action(.help),
              "/help parses to help action")
        check(ChatCommandParser.parse("/research iPhone battery life") == .action(.research(query: "iPhone battery life")),
              "/research captures the joined query")
        check(ChatCommandParser.parse("/research") == .usageError(message: "Use /research <query> — e.g. /research iPhone 18 battery life"),
              "/research alone yields a usage hint")
        check(ChatCommandParser.parse("/deep Apple Watch rings") == .action(.deepResearch(query: "Apple Watch rings")),
              "/deep parses to deep research")
        check(ChatCommandParser.parse("/DEEP Web Stuff") == .action(.deepResearch(query: "Web Stuff")),
              "command names are case-insensitive")
        check(ChatCommandParser.parse("/remember wifi is Nebula") == .action(.remember(fact: "wifi is Nebula")),
              "/remember captures the fact")
        check(ChatCommandParser.parse("/compute (4 + 6) * 3") == .action(.compute(expression: "(4 + 6) * 3")),
              "/compute captures the raw expression")
        check(ChatCommandParser.parse("/clear") == .action(.clear),
              "/clear parses")
        check(ChatCommandParser.parse("/clear now") == .usageError(message: "/clear takes no arguments."),
              "/clear with args rejects")
        check(ChatCommandParser.parse("/eval") == .action(.eval),
              "/eval parses")
        check(ChatCommandParser.parse("/bogus x") == .usageError(message: "Unknown command “/bogus”. Send /help to list available commands."),
              "unknown command yields usage error")
        check(ChatCommandParser.parse("/") == .usageError(message: ChatCommandParser.helpText),
              "lone slash yields help")
        check(ChatCommandParser.parse("read /tmp/notes") == .notACommand,
              "slash mid-sentence is not a command")
        check(ChatCommandParser.helpText.contains("/research <query>"),
              "help lists research usage")

        check(ExpressionEvaluator.evaluate("2+2") == 4, "2+2 = 4")
        check(ExpressionEvaluator.evaluate("2+2*3") == 8, "order of ops: 2+2*3 = 8")
        check(ExpressionEvaluator.evaluate("(4+6)*3") == 30, "(4+6)*3 = 30")
        check(ExpressionEvaluator.evaluate("10/4") == 2.5, "10/4 = 2.5")
        check(ExpressionEvaluator.evaluate("-3+2") == -1, "-3+2 = -1")
        check(ExpressionEvaluator.evaluate("-.5+1") == 0.5, "leading dot decimal: -.5+1 = 0.5")
        check(ExpressionEvaluator.evaluate("((2+3)*4)") == 20, "nested parens = 20")
        check(ExpressionEvaluator.evaluate("(2+2") == nil, "unbalanced paren rejected")
        check(ExpressionEvaluator.evaluate("abc") == nil, "letters rejected")
        check(ExpressionEvaluator.evaluate("0/0") == nil, "division by zero rejected")
        check(ExpressionEvaluator.evaluate("") == nil, "empty expression rejected")
        check(ExpressionEvaluator.format(12.0) == "12", "whole numbers format clean")
        check(ExpressionEvaluator.format(0.5) == "0.5", "decimals format as digits")

        if failures == 0 {
            print("Command: all checks passed")
        } else {
            print("Command: \(failures) check(s) FAILED")
        }
        exit(failures == 0 ? 0 : 1)
    }
}

func check(_ cond: Bool, _ message: String) {
    if cond {
        print("PASS \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}