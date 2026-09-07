import Foundation

/// Deterministic secret redaction for exports/sharing: replaces API-key-like
/// tokens, JWTs, Bearer headers, emails, and long random blobs with a fixed
/// placeholder so a shared file can't leak credentials.
enum SecretRedactor {
    static let placeholder = "[REDACTED]"

    /// Sanitize any free text (chat messages, markdown export, ...).
    static func redact(_ input: String) -> String {
        var out = input

        // Bearer tokens: `Bearer <opaque>`.
        out = regex("(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]{16,}") { _ in "Bearer \(placeholder)" }(out)

        // JWT / API-key style: `eyJ` base64url chunks, or prefix keys like
        // sk-xxxx / key=xxxx / api_key=xxxx / token=xxxx.
        out = regex("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{4,}\\.[A-Za-z0-9_-]{4,}") { _ in placeholder }(out)
        out = regex("(?i)(sk-[A-Za-z0-9]{16,}|[a-z0-9_-]*api[_]?key[a-z0-9_-]*\\s*[:=]\\s*[A-Za-z0-9._-]{12,}|[a-z0-9_-]*token[a-z0-9_-]*\\s*[:=]\\s*[A-Za-z0-9._-]{12,})")
            { match in
                let equalPos = (match as NSString).range(of: "=").location > 0 || (match as NSString).range(of: ":").location > 0
                guard equalPos else { return placeholder }
                return placeholder
            }(out)

        // Emails.
        out = regex("\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b", options: [.caseInsensitive]) { _ in "[email protected]" }(out)

        // Long unbroken alphanumeric blobs that look like credentials.
        out = regex("\\b[A-Za-z0-9+/=_\\-]{32,}\\b") { _ in placeholder }(out)

        return out
    }

    private static func regex(_ pattern: String,
                              options: NSRegularExpression.Options = [],
                              replace: @escaping (String) -> String) -> (String) -> String {
        return { input in
            guard let rx = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
            let range = NSRange(input.startIndex..., in: input)
            let matches = rx.matches(in: input, options: [], range: range)
            guard !matches.isEmpty else { return input }
            var result = input
            for match in matches.reversed() {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                let hit = String(result[swiftRange])
                result.replaceSubrange(swiftRange, with: replace(hit))
            }
            return result
        }
    }
}