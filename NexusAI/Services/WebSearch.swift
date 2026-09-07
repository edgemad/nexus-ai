import Foundation

/// Deep web search: queries search engines, fetches result pages, and extracts
/// cleaned text — Perplexity-style. No API key required.
struct WebResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: String
    var snippet: String
}

@MainActor
final class WebSearch: ObservableObject {
    @Published private(set) var isSearching = false
    @Published private(set) var results: [WebResult] = []
    @Published var error: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        ]
        return URLSession(configuration: cfg)
    }()

    func search(_ query: String, context: SearchContext) {
        Task {
            await run(query: query, context: context)
        }
    }

    /// Runs a full search (engine + optional page fetch) and returns results directly.
    func searchAsync(_ query: String, fetchPages: Bool = true, maxFetch: Int = 3) async -> [WebResult] {
        var context = SearchContext(fetchPages: fetchPages, maxFetch: maxFetch)
        var captured: [WebResult] = []
        context.onComplete = { captured = $0 }
        await run(query: query, context: context)
        return captured
    }

    private func run(query: String, context: SearchContext) async {
        isSearching = true
        error = nil
        defer { isSearching = false }

        var found: [WebResult] = []

        if context.allowDuckDuckGo {
            found = await searchDuckDuckGo(query)
        }
        if found.isEmpty && context.allowBing {
            found = await searchBing(query)
        }
        if found.isEmpty && context.allowMojeek {
            found = await searchMojeek(query)
        }

        var enriched: [WebResult] = []
        let top = found.prefix(context.maxFetch)
        for result in top {
            var entry = result
            if context.fetchPages {
                let text = await fetchText(result.url)
                if let t = trimBody(text) {
                    entry.snippet = t
                }
            }
            enriched.append(entry)
            if context.stopOnFirst { break }
        }

        results = enriched

        guard !enriched.isEmpty else {
            error = "No search results found."
            return
        }

        context.onComplete(enriched)
    }

    // MARK: - Engines

    private func searchDuckDuckGo(_ query: String) async -> [WebResult] {
        guard var comps = URLComponents(string: "https://html.duckduckgo.com/html/") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return [] }
            return parseDuckDuckGo(html: html)
        } catch {
            return []
        }
    }

    private func parseDuckDuckGo(html: String) -> [WebResult] {
        var out: [WebResult] = []
        // Extract result blocks between <a rel="nofollow" class="result__a" href="URL">TITLE</a>
        let pattern = "<a[^>]*class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        // Also capture snippets: class="result__snippet"
        let snipRegex = try? NSRegularExpression(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])

        for (i, m) in matches.enumerated() {
            guard i < 8 else { break }
            let hrefRange = m.range(at: 1)
            let titleRange = m.range(at: 2)
            guard hrefRange.location != NSNotFound else { continue }
            var href = ns.substring(with: hrefRange)
            var title = ns.substring(with: titleRange)
            title = stripTags(title).trimmingCharacters(in: .whitespacesAndNewlines)
            if href.hasPrefix("//") { href = "https:" + href }
            if !href.hasPrefix("http") { continue }
            // DuckDuckGo wraps in redirect (uddg=). Extract real URL.
            if let uddg = extractParam(href, name: "uddg") { href = uddg.removingPercentEncoding ?? uddg }
            var snippet = ""
            if let snipRegex,
               let sm = snipRegex.firstMatch(in: html, options: [], range: m.range) {
                let r = sm.range(at: 1)
                if r.location != NSNotFound { snippet = stripTags(ns.substring(with: r)) }
            }
            out.append(WebResult(title: title, url: href, snippet: snippet))
        }
        return out
    }

    private func searchBing(_ query: String) async -> [WebResult] {
        guard var comps = URLComponents(string: "https://www.bing.com/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return [] }
            return parseBing(html: html)
        } catch {
            return []
        }
    }

    private func parseBing(html: String) -> [WebResult] {
        var out: [WebResult] = []
        let pattern = "<h2><a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a></h2>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        for m in matches.prefix(8) {
            let href = ns.substring(with: m.range(at: 1))
            var title = stripTags(ns.substring(with: m.range(at: 2)))
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            var url = href
            if let u = extractParam(href, name: "url") { url = u.removingPercentEncoding ?? u }
            out.append(WebResult(title: title, url: url, snippet: ""))
        }
        return out
    }

    private func searchMojeek(_ query: String) async -> [WebResult] {
        guard var comps = URLComponents(string: "https://www.mojeek.com/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return [] }
            let pattern = "<a class=\"ob\" href=\"([^\"]+)\"[^>]*>(.*?)</a>"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
            let ns = html as NSString
            let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
            var out: [WebResult] = []
            for m in matches.prefix(8) {
                let url = ns.substring(with: m.range(at: 1))
                let title = stripTags(ns.substring(with: m.range(at: 2))).trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(WebResult(title: title, url: url, snippet: ""))
            }
            return out
        } catch {
            return []
        }
    }

    // MARK: - Page fetch & extraction

    func fetchText(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let text = String(data: data, encoding: .utf8) {
                let extracted = extractMainText(html: text, maxChars: 4000)
                // Many retail sites are JavaScript-rendered SPA pages: the raw
                // HTML contains only navigation, and the real content (terms,
                // offers, product details) is injected by JS after load. When we
                // detect a content-less page, fall back to rendering it with
                // headless Chrome so the user gets the actual details.
                if shouldRender(extracted) {
                    if let rendered = await fetchRendered(urlString) {
                        // Rendered pages keep their full navigation AND the
                        // real content (which usually sits after the menus), so
                        // give the render a large budget — the caller trims it
                        // down to the relevant region afterward.
                        return extractMainText(html: rendered, maxChars: 40_000)
                    }
                }
                return extracted
            }
            return nil
        } catch {
            return nil
        }
    }

    /// True when extracted text is dominated by site navigation/menus and is
    /// missing the kind of informative content a research answer needs. Such
    /// pages are strong candidates for JS rendering.
    private func shouldRender(_ text: String) -> Bool {
        let navMarkers = ["all sofas", "armchairs", "ottomans", "fabric", "leather", "blog", "instagram",
                          "gift cards", "buyers guides", "real estate", "sign in", "register",
                          "search for", "menu", "login", "subscribe"]
        let lower = text.lowercased()
        var navHits = 0
        for m in navMarkers where lower.contains(m) { navHits += 1 }
        // Too short, or heavily navigation-weighted → render.
        return text.count < 600 || navHits >= 5
    }

    /// Renders a URL with headless Chrome (installed locally) and returns the
    /// fully-executed DOM as a string, so JS-injected content is captured too.
    private func fetchRendered(_ urlString: String) async -> String? {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
        ]
        guard let chrome = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        let args = ["--headless", "--disable-gpu", "--no-sandbox", "--dump-dom",
                    "--virtual-time-budget=8000", "--user-agent=\(ua)", urlString]
        do {
            // Run the blocking Chrome process + pipe read on a background queue
            // so the MainActor (WebSearch is @MainActor) is never frozen.
            return try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global().async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: chrome)
                    proc.arguments = args
                    let pipe = Pipe()
                    let errPipe = Pipe()
                    proc.standardOutput = pipe
                    proc.standardError = errPipe
                    do {
                        try proc.run()
                    } catch {
                        cont.resume(returning: nil)
                        return
                    }
                    // Hard ceiling so a hung render never stalls the pipeline.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
                        if proc.isRunning { proc.terminate() }
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8))
                }
            }
        } catch {
            return nil
        }
    }

    private func extractMainText(html: String, maxChars: Int) -> String {
        var text = html
        // Strip HTML comments first — pages frequently embed developer notes in
        // <!-- --> that would otherwise leak into the extracted answer as junk.
        if let re = try? NSRegularExpression(pattern: "<!--[\\s\\S]*?-->", options: []) {
            text = re.stringByReplacingMatches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
        }
        text = stripScriptsAndStyles(text)
        text = stripTags(text)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxChars { text = String(text.prefix(maxChars)) }
        return text
    }

    private func stripScriptsAndStyles(_ html: String) -> String {
        var s = html
        if let re = try? NSRegularExpression(pattern: "<script[\\s\\S]*?</script>", options: []) {
            s = re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        if let re = try? NSRegularExpression(pattern: "<style[\\s\\S]*?</style>", options: []) {
            s = re.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        return s
    }

    private func stripTags(_ html: String) -> String {
        let ns = html as NSString
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            var out = re.stringByReplacingMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: " ")
            out = out.replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&nbsp;", with: " ")
            return out
        }
        return html
    }

    private func extractParam(_ url: String, name: String) -> String? {
        guard var comps = URLComponents(string: url) else { return nil }
        // urldecode query items
        comps.queryItems = comps.queryItems?.map {
            URLQueryItem(name: $0.name, value: $0.value?.removingPercentEncoding)
        }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }

    private func trimBody(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SearchContext {
    var allowDuckDuckGo = true
    var allowBing = true
    var allowMojeek = true
    var fetchPages = true
    var maxFetch = 3
    var stopOnFirst = false
    var onComplete: ([WebResult]) -> Void = { _ in }
}
