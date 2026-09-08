#!/usr/bin/env python3
"""
Nexie Research Service
======================
Pure-Python (stdlib-only, no pip deps) sidecar that performs Perplexity-style
web research and deep research, replicating the behavior previously embedded in
the SwiftUI app (WebSearch.swift + the research functions in ChatStore.swift).

Exposes a small HTTP API:

    GET  /health                 -> {"ok": true}
    POST /research               -> {"answer": str}   (single-pass web research)
    POST /deep                   -> {"answer": str}   (deep, two-pass research)

Request body (both /research and /deep):
    {
      "query": "current deal on freedom sofas",
      "llm_base": "http://127.0.0.1:8080/v1"   // optional; when reachable the
                                                 // LLM synthesizes the answer,
                                                 // otherwise the offline
                                                 // structured formatter is used
    }

Everything is stdlib: http.server, urllib, re, html.parser. No external deps.
"""

import html.parser
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

DEFAULT_LLM_BASE = os.environ.get("NEXIE_LLM_BASE", "http://127.0.0.1:8080/v1")
AUTH_TOKEN = os.environ.get("NEXIE_AUTH_TOKEN", "")
SERVICE_NAME = "nexie-research"
SERVICE_VERSION = "1.1.0"
_START_TIME = time.time()

# --------------------------------------------------------------------------
# Web result model
# --------------------------------------------------------------------------

class WebResult:
    __slots__ = ("title", "url", "snippet")

    def __init__(self, title, url, snippet=""):
        self.title = title
        self.url = url
        self.snippet = snippet

    def to_dict(self):
        return {"title": self.title, "url": self.url, "snippet": self.snippet}


# --------------------------------------------------------------------------
# HTML helpers (parsing/munging shared by search + page extraction)
# --------------------------------------------------------------------------

def strip_tags(text):
    text = re.sub(r"<[^>]+>", " ", text)
    for a, b in [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", '"'),
        ("&#39;", "'"),
        ("&nbsp;", " "),
    ]:
        text = text.replace(a, b)
    return text


def strip_scripts_and_styles(html_text):
    html_text = re.sub(r"<script[\s\S]*?</script>", " ", html_text, flags=re.I)
    html_text = re.sub(r"<style[\s\S]*?</style>", " ", html_text, flags=re.I)
    return html_text


def extract_main_text(html_text, max_chars=4000):
    text = re.sub(r"<!--[\s\S]*?-->", " ", html_text)
    text = strip_scripts_and_styles(text)
    text = strip_tags(text)
    text = re.sub(r"\s+", " ", text)
    text = text.strip()
    if len(text) > max_chars:
        text = text[:max_chars]
    return text


def extract_param(href, name):
    """URL-decode query params and pull the value for `name` (like DDG uddg=)."""
    try:
        parsed = urllib.parse.urlparse(href)
        qs = urllib.parse.parse_qs(parsed.query)
        if name in qs:
            return qs[name][0]
    except Exception:
        pass
    return None


# --------------------------------------------------------------------------
# Search engines
# --------------------------------------------------------------------------

def _geo_fetch(url):
    """Small fetch tailored for geolocation JSON APIs (they Cloudflare-gate the
    web-research UA, so keep it bare and tolerant of any hiccup)."""
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            if resp.status != 200:
                return None
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except Exception:
        return None

def geoip():
    """Approximate city-level location from the public IP. Returns '' when the
    network is unreachable or every geolocation service fails."""
    services = (
        ("https://get.geojs.io/v1/ip/geo.json", ("city", "region", "country")),
        ("https://ipwho.is/", ("city", "region", "country")),
        ("https://ipinfo.io/json", ("city", "region", "country")),
    )
    for url, keys in services:
        info = _geo_fetch(url)
        if not isinstance(info, dict):
            continue
        parts = [str(info.get(k)) for k in keys if info.get(k)]
        if parts:
            return ", ".join(parts)
    return ""

def http_get(url, timeout=20):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            return resp.read().decode("utf-8", errors="replace")
    except Exception:
        # A single blocked/protected page must never abort the whole pipeline.
        return None


def search_duckduckgo(query):
    url = "https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({"q": query})
    html_text = http_get(url)
    if not html_text:
        return []
    out = []
    pat = re.compile(r'<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>',
                     re.S | re.I)
    snip_pat = re.compile(r'class="result__snippet"[^>]*>(.*?)</a>', re.S | re.I)
    for i, m in enumerate(pat.finditer(html_text)):
        if i >= 8:
            break
        href = m.group(1)
        title = strip_tags(m.group(2)).strip()
        if href.startswith("//"):
            href = "https:" + href
        if not href.startswith("http"):
            continue
        uddg = extract_param(href, "uddg")
        if uddg:
            try:
                href = urllib.parse.unquote(uddg)
            except Exception:
                href = uddg
        snippet = ""
        sm = snip_pat.search(html_text, m.start())
        if sm:
            snippet = strip_tags(sm.group(1))
        out.append(WebResult(title=title, url=href, snippet=snippet))
    return out


def search_bing(query):
    url = "https://www.bing.com/search?" + urllib.parse.urlencode({"q": query})
    html_text = http_get(url)
    if not html_text:
        return []
    pat = re.compile(r'<h2><a[^>]*href="([^"]+)"[^>]*>(.*?)</a></h2>', re.S | re.I)
    out = []
    for m in list(pat.finditer(html_text))[:8]:
        href = m.group(1)
        title = strip_tags(m.group(2)).strip()
        u = extract_param(href, "url")
        if u:
            href = urllib.parse.unquote(u)
        out.append(WebResult(title=title, url=href, snippet=""))
    return out


def search_mojeek(query):
    url = "https://www.mojeek.com/search?" + urllib.parse.urlencode({"q": query})
    html_text = http_get(url)
    if not html_text:
        return []
    pat = re.compile(r'<a class="ob" href="([^"]+)"[^>]*>(.*?)</a>', re.S | re.I)
    out = []
    for m in list(pat.finditer(html_text))[:8]:
        page_url = m.group(1)
        title = strip_tags(m.group(2)).strip()
        out.append(WebResult(title=title, url=page_url, snippet=""))
    return out


def search(query):
    """Multi-engine search. Returns a list of WebResult (empty on total failure)."""
    found = search_duckduckgo(query)
    if not found:
        found = search_bing(query)
    if not found:
        found = search_mojeek(query)
    return found


# --------------------------------------------------------------------------
# Page fetch + JS rendering fallback
# --------------------------------------------------------------------------

def should_render(text):
    nav_markers = [
        "all sofas", "armchairs", "ottomans", "fabric", "leather", "blog", "instagram",
        "gift cards", "buyers guides", "real estate", "sign in", "register",
        "search for", "menu", "login", "subscribe",
    ]
    lower = text.lower()
    hits = sum(1 for m in nav_markers if m in lower)
    return len(text) < 600 or hits >= 5


def fetch_rendered(url_str):
    candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ]
    chrome = next((c for c in candidates if os.path.exists(c)), None)
    if not chrome:
        return None
    args = [
        "--headless", "--disable-gpu", "--no-sandbox", "--dump-dom",
        "--virtual-time-budget=8000", f"--user-agent={USER_AGENT}", url_str,
    ]
    try:
        proc = subprocess.run(
            [chrome] + args,
            capture_output=True,
            timeout=25,
        )
        return proc.stdout.decode("utf-8", errors="replace")
    except Exception:
        return None


def fetch_text(url_str):
    """Fetch + extract from a URL, falling back to headless-Chrome rendering."""
    parsed = urllib.parse.urlparse(url_str)
    if parsed.scheme not in ("http", "https"):
        return None
    html_text = http_get(url_str)
    if not html_text:
        return None
    extracted = extract_main_text(html_text, max_chars=4000)
    if should_render(extracted):
        rendered = fetch_rendered(url_str)
        if rendered:
            return extract_main_text(rendered, max_chars=40000)
    return extracted


def enrich_results(results, fetch_pages=True, max_fetch=3):
    """Fetch page bodies for the top results and return enriched WebResults."""
    enriched = []
    for i, result in enumerate(results[:max_fetch]):
        entry = WebResult(result.title, result.url, result.snippet)
        if fetch_pages:
            text = fetch_text(result.url)
            if text and text.strip():
                entry.snippet = text
        enriched.append(entry)
    return enriched


def search_and_fetch(query, max_fetch=3):
    """Full search => fetch pipeline used by both research passes."""
    results = search(query)
    if not results:
        return []
    return enrich_results(results, fetch_pages=True, max_fetch=max_fetch)


# --------------------------------------------------------------------------
# Relevance + official-domain prioritization (port of static funcs)
# --------------------------------------------------------------------------

def official_host(query):
    l = query.lower()
    domain_pat = re.compile(
        r"([a-z0-9-]+\.(?:com\.au|co\.uk|co\.nz|\.com|\.org|\.net|\.io|\.co|\.au|\.gov|\.edu))",
        re.I,
    )
    m = domain_pat.search(l)
    if not m:
        return None
    host = m.group(1)
    return host.replace("www.", "")


def relevant_results(query, results):
    q_words = set(
        w
        for w in re.split(r"[^A-Za-z]", query.lower())
        if len(w) > 2 and w not in {
            "the", "and", "for", "with", "what", "are", "how", "get",
            "can", "any", "com", "au", "www", "want", "about",
        }
    )
    if not q_words:
        return results
    query_host = official_host(query)
    out = []
    for r in results:
        if query_host:
            try:
                h = urllib.parse.urlparse(r.url).hostname or ""
                if h.lower().endswith(query_host):
                    out.append(r)
                    continue
            except Exception:
                pass
        text = (r.title.lower() + " " + r.url.lower())
        if any(w in text for w in q_words):
            out.append(r)
    return out


def prioritize_official_pages(query, results):
    query_host = official_host(query)
    if not query_host:
        return results
    official, authoritative, rest = [], [], []
    for r in results:
        try:
            host = (urllib.parse.urlparse(r.url).hostname or "").lower()
        except Exception:
            host = ""
        title = r.title.lower()
        if host.endswith(query_host):
            official.append(r)
        elif (
            "term" in title or "condition" in title or "promotion" in title
            or ("offer" in title and "code" not in title)
        ):
            authoritative.append(r)
        else:
            rest.append(r)
    return official + authoritative + rest


def deep_refine_query(query):
    forbidden = set(
        "a an the is are was were to of in on for and or with at by from it its "
        "this that be have had has what when where who how which there some into "
        "about as not no yes you your their our does do did will would can could "
        "so but if they them then than these those out up down off over under "
        "again further".split()
    )
    words = [
        w
        for w in re.split(r"[^A-Za-z0-9]", query.lower())
        if len(w) >= 4 and w not in forbidden
    ]
    picked = words[:3]
    if not picked:
        return query
    return " ".join(picked) + " 2026 details"


# --------------------------------------------------------------------------
# Page-body cleaning + relevant-region trimming (port of static funcs)
# --------------------------------------------------------------------------

def clean_page_text(raw):
    t = raw
    t = re.sub(r"MUST stay[^.]*\.", " ", t)
    t = re.sub(r'(no type=|type=""module""|async|defer)', " ", t)
    t = t.replace("oauth-transport-guard.js", " ")
    t = re.sub(r"Skip to (Header|Main Content|Footer|main content)", " ", t)
    t = t.replace("Submit a request Sign in", " ")
    t = re.sub(r"Article(s)? in this section", " ", t)
    t = re.sub(r"Table of Contents", " ", t)
    t = re.sub(r"\s{2,}", " ", t)
    return t.strip()


def relevant_terms_region(query, body, max_chars=6000):
    """Port of relevantTermsRegion: anchor on numbered clause start or the last
    terms-style heading that still has content behind it."""
    l = query.lower()
    wants_terms = any(k in l for k in
                      ["term", "condition", "duration", "detail", "exact", "full",
                       "exclusion", "fine print", "eligib"])
    if not wants_terms:
        return body[:1500]
    if not body:
        return body

    # 1) Numbered clause start, e.g. "1. 'At Least 30% Off Storewide' ..."
    clause_pat = re.compile(
        r'^\s*1\.\s*[\'’"\u201c\u201d]?\s*[A-Z]|1\.\s*[\'’"\u201c\u201d]?\s*[A-Z]'
    )
    m = clause_pat.search(body)
    if m:
        start = m.start()
        segment = body[start:start + max_chars]
        if len(segment) >= 120:
            return segment

    # 2) Fallback: last terms-style heading still having >=150 chars after it.
    anchors = ["terms & conditions", "full terms and conditions", "promotions & offers"]
    best = None
    for anchor in anchors:
        pos = 0
        while True:
            idx = body.lower().find(anchor, pos)
            if idx == -1:
                break
            following = len(body) - (idx + len(anchor))
            if following >= 150:
                best = idx + len(anchor)
            pos = idx + len(anchor)
    if best is not None:
        return "…" + body[best:best + max_chars]
    return body[:1500]


# --------------------------------------------------------------------------
# LLM synthesis (llama-server OpenAI-compatible)
# --------------------------------------------------------------------------

def llm_reachable(llm_base, timeout=4):
    try:
        req = urllib.request.Request(llm_base.rstrip("/") + "/models",
                                     headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status == 200
    except Exception:
        return False


def llm_complete(system, user, llm_base=DEFAULT_LLM_BASE, max_tokens=2048, temperature=0.3):
    """Non-streaming single-shot completion against the local llama-server."""
    body = {
        "model": "local",
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": temperature,
        "stream": False,
        "max_tokens": max_tokens,
    }
    req = urllib.request.Request(
        llm_base.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode("utf-8", errors="replace"))
        choices = data.get("choices") or []
        if choices:
            return (choices[0].get("message") or {}).get("content") or ""
    except Exception:
        pass
    return ""


# --------------------------------------------------------------------------
# Evidence-backed research: inline citations, marination, verdict confidence
# --------------------------------------------------------------------------

CITATION_RE = re.compile(r"\[(\d{1,2})\]")


def citation_indexes(text):
    """Unique, ascending inline citation numbers, e.g. "[2] … [1] [3]" → [1,2,3]."""
    seen, out = set(), []
    for m in CITATION_RE.finditer(text):
        try:
            n = int(m.group(1))
        except ValueError:
            continue
        if n not in seen:
            seen.add(n)
            out.append(n)
    return sorted(out)


def trace_confidence(answer, sources, marinated):
    """0–95 deterministic verdict confidence (mirrors EvidenceScorer in Swift)."""
    if not answer or not sources:
        return 0
    trace = sum(1 for n in citation_indexes(answer) if 1 <= n <= len(sources))
    score = 50 if trace > 0 else 30
    score += int((min(trace, len(sources)) / float(len(sources))) * 30)
    if marinated:
        score += 15
    return min(score, 95)


def marinate(query, sources_text, draft, llm_base, max_rounds=1):
    """Reflection loop: a critique pass checks the draft against the sources,
    then a revision pass folds the critique in. Returns (revised_answer,
    marinated_flag). The draft is returned unchanged if any call fails."""
    crit = llm_complete(
        "You are a strict fact-checker. Read the WEB SOURCES and the RESEARCH "
        "DRAFT below. List each claim in the draft that (a) is not supported by "
        "any source, (b) has the wrong inline citation number, or (c) misses an "
        "obvious value the sources state. Be terse: 'OK' if the draft is "
        "accurate, otherwise bullet points starting with UNSUPPORTED / "
        "WRONG-CITE / MISSING. Never invent new facts.\n\nWEB SOURCES:\n"
        + sources_text + "\n\nRESEARCH DRAFT:\n" + draft,
        query, llm_base=llm_base, max_tokens=1024, temperature=0.0,
    )
    if not crit or crit.strip().lower().startswith("ok"):
        return draft, False
    revised = llm_complete(
        "You are a precise research assistant. Revise the RESEARCH DRAFT "
        "according to the CRITIQUE: drop or fix unsupported claims, correct "
        "citation numbers, add the missing concrete values. Keep the same "
        "overall structure and length. Do not introduce anything the sources "
        "do not support.\n\nWEB SOURCES:\n" + sources_text +
        "\n\nCRITIQUE:\n" + crit + "\n\nRESEARCH DRAFT:\n" + draft,
        query, llm_base=llm_base, max_tokens=2048, temperature=0.2,
    )
    if not revised:
        return draft, False
    return revised, True


def research_payload(answer, results, output_sources, marinated):
    """Bundle the answer with its evidence for the HTTP response."""
    return {
        "answer": answer,
        "sources": [s.to_dict() for s in output_sources],
        "confidence": trace_confidence(answer, output_sources, marinated),
        "marinated": marinated,
    }


# --------------------------------------------------------------------------
# Offline structured answer — faithful port of ChatStore.structuredAnswer & co.
# --------------------------------------------------------------------------

def is_promotional(query):
    l = query.lower()
    strong = ["deal", "promo", "promotion", "discount", "sale", "voucher", "coupon"]
    if any(w in l for w in strong):
        return True
    if re.search(r"\boffer\b", l) and ("current " in l or re.search(r"\boff\b", l) or "on sale" in l):
        return True
    if re.search(r"\bprice\b", l) and (re.search(r"\boff\b", l) or "deal" in l):
        return True
    if "how much is" in l:
        return True
    return False


def full_details_block(query, sources):
    want_full = any(k in query.lower() for k in
                    ["terms", "condition", "duration", "detail", "full", "exact", "all the terms"])
    candidates = []
    for s in sources:
        t = s["title"].lower()
        b = s["body"].lower()
        if ("term" in t or "condition" in t or "promotion" in t
                or "terms & conditions" in b or "not available in conjunction" in b
                or "not available with any other" in b):
            candidates.append(s)
    pool = candidates if candidates else sources
    if not pool:
        return None
    best = max(pool, key=lambda s: len(s["body"]))
    body = best["body"].strip()
    if len(body) < 120:
        return None
    numbered_clause = re.compile(r"1\.\s*[\'’\"\u201c\u201d]?\s*[A-Z]")
    body_lower = body.lower()
    looks_like = (bool(numbered_clause.search(body))
                  or "terms & conditions" in body_lower
                  or "excludes" in body_lower
                  or "not available" in body_lower)
    if not (want_full or looks_like):
        return None
    shown = body[:2200] + "…" if len(body) > 2200 else body
    return f"• {best['title']}\n{shown}"


def matches(pattern, text, flags=re.I):
    re_flags = flags | (re.I if isinstance(flags, int) else 0)
    return [m.group(0) for m in re.finditer(pattern, text, flags=re_flags)]


def capitalize_months(s):
    months = ["january", "february", "march", "april", "may", "june", "july",
              "august", "september", "october", "november", "december"]
    fixed = s
    for month in months:
        fixed = fixed.replace(f" {month} ", f" {month.capitalize()} ")
    return fixed


def clean_date(raw):
    t = raw.strip()
    lead = t.lower()
    for hit, rep in [("available from ", "runs from "), ("running from ", "runs from "),
                     ("starts ", "runs from ")]:
        if lead.startswith(hit):
            t = rep + t[len(hit):]
            break
    return capitalize_months(t)


def offer_phrase(sentence):
    pat = re.compile(r"(% off|\bup to \d{1,3}([-\u2013]\d{1,3})?\s?%|save up to \$?\d[\d,]*)", re.I)
    cutters = [" Promotional ", " and up to ", " is available ", " available from ", " from ",
               " for ", " until ", " through ", ", ", ";", ":", " – ", " — "]
    quote = re.compile(r"[\"\u201c\u201d\u2018\u2019]([^\"\u201c\u201d\u2018\u2019]{3,140})[\"\u201c\u201d\u2018\u2019]")
    mq = quote.search(sentence)
    if mq:
        title = mq.group(1)
        if re.search(r"%|save|up to", title):
            return clean_offer(title, cutters)
    m = pat.search(sentence)
    if not m:
        return ""
    start = m.start()
    top = min(len(sentence), start + 120)
    slice_ = sentence[start:top]
    candidate = slice_
    if slice_.startswith("%"):
        pre = re.sub(r"\s+", " ", sentence[:start]).strip()
        lpre = pre.lower()
        has_letter = bool(re.search(r"[A-Za-z]", pre))
        if (len(pre) >= 5 and len(pre) <= 45 and has_letter
                and all(c not in pre for c in [".", ":", "/"])
                and " from " not in lpre and " until " not in lpre):
            candidate = pre + slice_
    return clean_offer(candidate, cutters)


def clean_offer(slice_, cutters):
    best = slice_
    best_dist = 10 ** 9
    for cut in cutters:
        idx = slice_.find(cut)
        if idx != -1 and idx < best_dist:
            best_dist = idx
            best = slice_[:idx]
    t = best.strip()
    while t and t[-1] in "’\"'“”‘’[":
        t = t[:-1]
    return t.strip()


def normalize_deal(frag):
    t = frag.strip()
    low = t.lower()
    if low.startswith("up to ") or low.startswith("up ") or low.startswith("upto "):
        t = re.sub(r"(?i)^up\s?to\s*", "", t)
        t = "up to " + t
    if ("%" in t and " off" not in t.lower() and " discount" not in t.lower()
            and " saving" not in t.lower() and " back" not in t.lower()):
        t += " off"
    elif t.lower().startswith("save ") and "on " not in t and "until " not in t:
        t += " on furniture"
    return t


def titlize(s):
    t = s.strip()
    if not t:
        return "The sources I fetched cover the current status, but the pages have updated their wording."
    out = t[0].upper() + t[1:]
    if not out.endswith("."):
        out += "."
    return out


def nearest_expiry(sources):
    pat = re.compile(r"((?:until|by|ends?|expires?|valid)\s+[^.]{0,40}(?:20\d{2}))", re.I)
    months = ["january", "february", "march", "april", "may", "june", "july",
              "august", "september", "october", "november", "december"]
    for s in sources:
        for m in matches(pat, s["body"]):
            trimmed = m.strip()
            if len(trimmed) < 12:
                continue
            fixed = trimmed
            for month in months:
                fixed = fixed.replace(f" {month} ", f" {month.capitalize()} ")
            return fixed
    return None


def sentence_parts(body):
    body = re.sub(r"\s+", " ", body)
    body = re.sub(r"(?<!\d)\.(?=\s)", ".¶", body)
    parts = []
    for p in body.split("¶"):
        t = p.strip()
        if len(t) >= 15:
            parts.append(t)
    return parts


def most_relevant_sentences(query, sources, limit=3):
    q_words = set(
        w for w in re.split(r"[^A-Za-z]", query.lower())
        if len(w) > 2 and w not in {
            "the", "and", "for", "with", "from", "what", "are", "you", "not", "off", "how",
        }
    )
    boiler = ["subscribe", "log in", "sign in", "menu", "close", "skip to content", "my account",
              "saved articles", "search for", "view search results", "newsletter", "facebook",
              "instagram", "pinterest", "privacy", "terms", "cookie"]
    scored = []  # (score, text)
    for s in sources:
        body = re.sub(r"\s+", " ", s["body"])
        sentences = re.split(r"[.!?;:]+(?=\s)", body)
        for sent in sentences:
            t = sent.strip()
            if not (40 <= len(t) <= 320):
                continue
            low = t.lower()
            if any(b in low for b in boiler):
                continue
            words = re.split(r"[^A-Za-z%]", low)
            score = sum(1 for w in words if w in q_words)
            if score >= 1:
                scored.append((score, t))
    scored.sort(key=lambda x: (-x[0], len(x[1])))
    out = [t for _, t in scored[:limit]]
    if not out:
        for s in sources:
            parts = re.split(r"(?<!\d)\.(?=\s)", s["body"])
            parts = [p.strip() for p in parts if len(p.strip()) >= 15]
            if parts:
                out = parts[:2]
                break
    return out


def subject_phrase(query):
    s = query
    for prefix in ["whats the current deal on", "what's the current deal on", "what is the current deal on",
                   "whats the deal on", "what's the deal on", "current deal on", "what are the current",
                   "whats the current", "what's the current", "current offers at", "what is the current offer on"]:
        if s.lower().startswith(prefix):
            s = s[len(prefix):].strip()
            break
    s = s.strip("?.!, ")
    if not s:
        return "this retailer"
    clean = s.replace("www.", "")
    domain = re.sub(r"\.(com\.au|\.com|\.co|\.net|\.org|\.au)$", "", clean)
    words = domain.split(".")[0] if "." in domain else domain
    if not words:
        return "this retailer"
    return words[:1].upper() + words[1:]


def offer_scope(query, sources):
    categories = ["sofas", "sofa", "furniture", "mattresses", "mattress", "homewares",
                  "outdoor furniture", "outdoor", "rugs", "bedroom", "dining", "chairs", "occasional"]
    l = query.lower()
    for cat in categories:
        if f"{cat} off" in l or f" on {cat}" in l:
            return "sofas" if cat == "sofa" else ("mattresses" if cat == "mattress" else cat)
    for cat in categories:
        if cat in l:
            return "sofas" if cat == "sofa" else ("mattresses" if cat == "mattress" else cat)
    joined = " ".join(s["body"].lower() for s in sources)
    for cat in ["sofas", "mattresses", "homewares", "outdoor", "furniture", "rugs"]:
        if f"all {cat}" in joined or f" {cat} until " in joined:
            return cat
    if "all sofas" in joined or "sofas until" in joined:
        return "sofas"
    return None


def first_paragraph(query, sources):
    offers = offer_facts(sources)
    if len(offers) >= 1 and is_promotional(query):
        headline = normalize_deal(offers[0]).lower()
        subject = subject_phrase(query)
        scope = offer_scope(query, sources)
        expiry = nearest_expiry(sources)
        if scope and expiry:
            line = f"The main current deal on {subject} {scope} is {headline}, {expiry}."
        elif scope:
            line = f"The main current deal on {subject} {scope} is {headline}."
        elif expiry:
            line = f"The main current deal on {subject} is {headline}, {expiry}."
        else:
            line = f"The main current deal on {subject} is {headline}."
        return titlize(line)
    best = most_relevant_sentences(query, sources, limit=3)
    lead = " ".join(best) if best else (
        "The fetched pages are live but didn't state a clear answer to your exact question."
    )
    return titlize(lead)


def offer_facts(sources):
    facts = []
    patterns = [
        r"up to \d{1,3}\s?% (?=off|discount|saving)",
        r"\d{1,3}\s?% off",
        r"save (up to )?\$?\d[\d,]*(\.\d+)?( %|%)?",
        r"save \$?[\d,]+",
        r"(from|until|ends|runs|valid)( [a-z]+ )?\d{1,2} \w+ 20\d\d",
        r"10% back",
        r"free delivery",
    ]
    date_pat = re.compile(r"(\d{1,2}[/ .]\d{1,2}[/ .]\d{2,4}|\d{1,2} \w+ 20\d\d|\d{1,2} \w{3} \d{2,4})")
    for s in sources:
        for p in patterns:
            for m in matches(p, s["body"])[:3]:
                trimmed = m.strip()
                if trimmed and trimmed not in facts:
                    facts.append(trimmed)
        dates = list(date_pat.finditer(s["body"]))[:2]
        if len(dates) >= 2:
            buf = f"Offer period: {dates[0].group(1)} – {dates[1].group(1)}"
            if buf not in facts:
                facts.append(buf)
    return facts


def top_facts(sources, limit=4):
    boiler = ["subscribe", "log in", "sign in", "menu", "close", "skip to content",
              "my account", "newsletter", "cookie", "facebook", "instagram"]
    facts = []
    for s in sources:
        chunks = re.split(r"[.!?;:]+(?=\s)", re.sub(r"\s+", " ", s["body"]))
        for c in chunks:
            t = c.strip()
            if not (30 <= len(t) <= 220):
                continue
            low = t.lower()
            if any(b in low for b in boiler):
                continue
            if not any(t == f or t in f or f in t for f in facts):
                facts.append(t)
            if len(facts) >= limit:
                return facts
    return facts


def promotion_bullets(sources, limit=6):
    offer_pat = re.compile(r"(?i)% off|\bup to \d{1,3}([-\u2013]\d{1,3})?\s?%|save up to \$?\d[\d,]*")
    date_pat = re.compile(
        r"(?:from|available from|runs from|starting)\s+[^.;]{0,90}?(?:until|to|through|\u2013)\s+(?:midnight on\s+)?[^.;]{0,45}?(?:19|20)\d{2}",
        re.I,
    )
    out = []
    for s in sources:
        for sentence in sentence_parts(s["body"]):
            if not (len(sentence) <= 260 and offer_pat.search(sentence)):
                continue
            offer = offer_phrase(sentence)
            if not offer:
                continue
            if any(offer.lower() == o.lower() or offer.lower() in o.lower() or o.lower() in offer.lower() for o in out):
                continue
            bullet = offer
            dm = matches(date_pat, sentence)
            if dm:
                bullet += " — " + clean_date(dm[0].strip())
            out.append(bullet)
            if len(out) >= limit:
                return out
    return out


def term_sentences(sources, limit=8):
    keys = ["not available", "in conjunction", "cannot be combined", "cannot be used", "not be used",
            "not valid", "exclud", "while stocks last", "normal retail quantit", "new orders",
            "100% payment", "full payment", "payment at the", "based on the", "recommended retail",
            "retail price", "r.r.p", "rrp", "standard terms", "gift card", "does not apply",
            "not applicable", "clearance", "subject to availability", "quantities only"]
    boiler = ["subscribe", "sign in", "log in", "menu", "cookie", "my account", "newsletter"]
    out = []
    for s in sources:
        for sentence in sentence_parts(s["body"]):
            l = sentence.lower()
            if not (len(l) <= 170 and any(k in l for k in keys)):
                continue
            if "% off" in l:
                continue
            if re.match(r"^\s*\d+\.\s*[\"\u201c\u201d\u2018\u2019]?.{0,8}% off|^\s*\d+\.\s*[\"\u201c\u201d\u2018\u2019]?.{0,12}save up to", l):
                continue
            if any(b in l for b in boiler):
                continue
            if not any(sentence == f or sentence in f or f in sentence for f in out):
                out.append(sentence)
            if len(out) >= limit:
                return out
    return out


def bullets(items):
    if not items:
        return "• None clearly stated in the sources I could fetch."
    return "\n".join(f"• {item}" for item in items)


def best_pick(query, sources, offers):
    l = query.lower()
    note = "Go with the freshest headline offer above — the one with the nearest expiry is usually the most prominent current promotion."
    expiry = nearest_expiry(sources)
    if expiry:
        note = (f"If you're after one pick, choose the offer {expiry} — that's the headline, "
                f"time-sensitive deal. The other discounts still run, but they're broader and less urgent.")
    elif offers:
        note = (f"If you want the single headline deal right now, it's \u201c{offers[0].lower()}\u201d "
                f"— the most clearly stated current offer. The others are broader and run longer.")
    if any(k in l for k in ["term", "condition", "promotion", "eligible"]):
        note += " Confirm the item is in the eligible range and no clearance/gift-card exclusions apply before you buy."
    return note


def closing_offer_note(query, sources):
    subject = subject_phrase(query)
    bodies = " ".join(s["body"].lower() for s in sources)
    categories = [("sofas", "sofas"), ("mattresses", "mattresses"), ("outdoor", "outdoor furniture"),
                  ("bedroom", "bedroom furniture"), ("homewares", "homewares"), ("rugs", "rugs"),
                  ("dining", "dining furniture"), ("casegoods", "casegoods")]
    found = []
    for needle, label in categories:
        if needle in bodies:
            found.append(label)
            if len(found) >= 3:
                break
    list_ = ", ".join(found) if found else "which item"
    if subject and subject.lower() != "this retailer":
        return (f"If you tell me what you're looking to buy ({list_}), I'll map the {subject} "
                f"promotion that applies and the effective discount and conditions for that category.")
    return (f"If you tell me what you're looking to buy ({list_}), I'll point you to the promotion "
            f"that applies and the exact conditions for that category.")


def structured_answer(query, sources):
    """Faithful port of ChatStore.structuredAnswer — Perplexity-style layout."""
    non_empty = [s for s in sources if s["body"].strip()]
    if not non_empty:
        fallback = "\n\n".join(f"• {s['title']}\n  {s['url']}" for s in sources[:3])
        return f"Here's what I found for \u201c{query}\u201d:\n\n{fallback}"

    promo = is_promotional(query)
    lines = [first_paragraph(query, non_empty), ""]

    if promo:
        promos = promotion_bullets(non_empty)
        if promos:
            lines.append("## Current promotions")
            lines.append(bullets(promos))
            lines.append("")
        terms = term_sentences(non_empty)
        if terms:
            lines.append("## Main terms and conditions")
            lines.append("Across these offers, the retailer applies broadly similar conditions:")
            lines.append(bullets(terms))
            lines.append("")
    else:
        facts = top_facts(non_empty, limit=4)
        if facts:
            lines.append("## Key points")
            lines.append(bullets(facts))
            lines.append("")

    full = full_details_block(query, non_empty)
    if full:
        lines.append("## Full details")
        lines.append(full)
        lines.append("")

    if promo:
        offers = offer_facts(non_empty)
        if offers:
            lines.append("## Best pick")
            lines.append(best_pick(query, non_empty, offers))
            lines.append("")
        lines.append(closing_offer_note(query, non_empty))
        lines.append("")

    lines.append("## Sources")
    seen_hosts = set()
    shown = 0
    for i, s in enumerate(sources):
        if not s["title"]:
            continue
        if shown >= 5:
            break
        try:
            host = (urllib.parse.urlparse(s["url"]).hostname or "").replace("www.", "")
        except Exception:
            host = ""
        if host:
            if host in seen_hosts:
                continue
            seen_hosts.add(host)
        lines.append(f"[{i + 1}] {s['title']} — {s['url']}")
        shown += 1
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Research pipelines (ports of runWebResearch / runDeepResearch)
# --------------------------------------------------------------------------

def build_sources_text(results, query, first_max=6000, other_max=2200):
    """Format the enriched results for the model prompt (port of the map)."""
    lines = []
    for i, r in enumerate(results):
        body = relevant_terms_region(query, clean_page_text(r.snippet),
                                     max_chars=first_max if i == 0 else other_max)
        shown = body if body else r.snippet[:300]
        lines.append(f"• {r.title} ({r.url}): {shown}")
    return "\n".join(lines)


def run_web_research(query, llm_base=DEFAULT_LLM_BASE):
    raw = search_and_fetch(query, max_fetch=5)
    if not raw:
        return {}
    relevant = relevant_results(query, raw)
    results = prioritize_official_pages(query, relevant)[:4]
    if not results:
        return {}

    if llm_reachable(llm_base):
        sources_text = build_sources_text(results, query)
        system = (
            "You are a precise research assistant. Answer ONLY the user's question DIRECTLY and "
            "nothing unrelated. Lead with a one or two sentence direct answer that re-states what "
            "was asked. Then, only if the facts genuinely need it, support it with a couple of short "
            "\"•\" bullet lines (exact values, dates, names). Do NOT invent sections, do NOT pad with "
            "extra angles, and do NOT include a \"Takeaway\" label — the direct answer up top IS the "
            "takeaway. Quote the EXACT wording from a source with an inline cite like [1] only where "
            "it supports the point. Date ranges fully, e.g. \"Runs from 25 August 2026 through "
            "midnight on 31 August 2026\". If a source doesn't actually answer the question, ignore it "
            "entirely. If the sources cannot answer the question, say so in one sentence instead of "
            "guessing.\n\nWEB SOURCES:\n" + sources_text
        )
        out = llm_complete(system, query, llm_base=llm_base)
        if out:
            out, marinated = marinate(query, sources_text, out, llm_base)
            return research_payload(out, results, results, marinated)

    cleaned = [
        {"title": r.title, "url": r.url,
         "body": relevant_terms_region(query, clean_page_text(r.snippet), max_chars=9000)}
        for r in results
    ]
    answer = structured_answer(query, cleaned)
    return research_payload(answer, results, results, False)


def run_deep_research(query, llm_base=DEFAULT_LLM_BASE):
    pass1 = search_and_fetch(query, max_fetch=8)
    refined = deep_refine_query(query)
    merged = list(pass1)
    if refined != query:
        pass2 = search_and_fetch(refined, max_fetch=5)
        seen = {r.url for r in merged}
        merged += [r for r in pass2 if r.url not in seen]
    if not merged:
        return {}

    relevant = relevant_results(query, merged)
    results = prioritize_official_pages(query, relevant)[:6]
    if not results:
        return {}

    if llm_reachable(llm_base):
        sources_text = build_sources_text(results, query, first_max=7000, other_max=2800)
        system = (
            "You are a deep research assistant but your FIRST job is staying on-topic. Lead with a "
            "one or two line bottom-line takeaway that directly answers the user's exact question. "
            "Then, only where it genuinely helps, add a short structured body using clearly labelled "
            "sections (\"## Key points\", \"## Comparisons\", \"## Bottom line\"). NEVER pad: only "
            "add a section if it has concrete, relevant content about the question. Cover other "
            "angles ONLY if they are directly relevant to what was asked — otherwise skip them. Cite "
            "each fact inline as [1], [2], etc., matching the numbered WEB SOURCES below, only where "
            "a source genuinely supports the point. Ignore any source that doesn't actually answer "
            "the question. End with the bottom-line recommendation. If the sources cannot answer the "
            "question, say so in one sentence rather than guessing.\n\nWEB SOURCES:\n" + sources_text
        )
        out = llm_complete(system, query, llm_base=llm_base)
        if out:
            out, marinated = marinate(query, sources_text, out, llm_base)
            return research_payload(out, results, results, marinated)

    cleaned = [
        {"title": r.title, "url": r.url,
         "body": relevant_terms_region(query, clean_page_text(r.snippet), max_chars=9000)}
        for r in results
    ]
    answer = structured_answer(query, cleaned)
    return research_payload(answer, results, results, False)


# --------------------------------------------------------------------------
# HTTP server
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    request_count = 0

    def log_message(self, fmt, *args):  # quieter logs
        pass

    def _authorized(self):
        if not AUTH_TOKEN:
            return True
        expected = "Bearer " + AUTH_TOKEN
        return (self.headers.get("Authorization") or "") == expected

    def _unauthorized(self):
        self._json(401, {
            "ok": False,
            "error": {
                "code": "unauthorized",
                "message": "missing or invalid auth token",
                "retryable": False,
                "request_id": None,
            },
        })

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def _maybe_cors(self):
        # Native app requests carry no Origin header, so they are unaffected.
        # Echo an Access-Control-Allow-Origin only for local browser origins
        # (loopback-only web consoles); any other browser origin is silently
        # blocked by the browser because no CORS header is sent.
        origin = self.headers.get("Origin")
        if origin and (origin.startswith("http://localhost:")
                       or origin.startswith("http://127.0.0.1:")):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._maybe_cors()
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        Handler.request_count += 1
        path = self.path.split("?", 1)[0]
        if path == "/health" or path.startswith("/health"):
            self._json(200, {"ok": True, "service": SERVICE_NAME})
        elif path == "/version":
            if not self._authorized():
                return self._unauthorized()
            self._json(200, {"ok": True, "service": SERVICE_NAME,
                             "version": SERVICE_VERSION})
        elif path == "/capabilities":
            if not self._authorized():
                return self._unauthorized()
            self._json(200, {
                "ok": True,
                "service": SERVICE_NAME,
                "capabilities": {
                    "web_research": True,
                    "deep_research": True,
                    "geoip": True,
                    "source_ranking": True,
                    "structured_errors": True,
                    "auth": bool(AUTH_TOKEN),
                    "shutdown": True,
                },
            })
        elif path == "/metrics":
            if not self._authorized():
                return self._unauthorized()
            self._json(200, {
                "ok": True,
                "service": SERVICE_NAME,
                "requests": Handler.request_count,
                "uptime_seconds": int(time.time() - _START_TIME),
            })
        elif path == "/geoip":
            if not self._authorized():
                return self._unauthorized()
            self._json(200, {"ok": True, "place": geoip()})
        else:
            self._json(404, {"ok": False,
                             "error": {"code": "not_found",
                                       "message": "not found",
                                       "retryable": False,
                                       "request_id": None}})

    def do_POST(self):
        Handler.request_count += 1
        path = self.path.split("?", 1)[0]
        if not self._authorized():
            return self._unauthorized()
        if path == "/shutdown":
            threading.Timer(0.15, self.server.shutdown).start()
            self._json(200, {"ok": True, "shutting_down": True})
            return
        payload = self._read_json()
        query = (payload.get("query") or "").strip()
        llm_base = payload.get("llm_base") or DEFAULT_LLM_BASE
        if not query:
            self._json(400, {"ok": False,
                             "error": {"code": "invalid_input",
                                       "message": "missing query",
                                       "retryable": False,
                                       "request_id": None}})
            return
        try:
            if path == "/deep":
                payload = run_deep_research(query, llm_base=llm_base)
            else:  # /research
                payload = run_web_research(query, llm_base=llm_base)
            if not isinstance(payload, dict):
                payload = {}
            response = {
                "ok": True,
                "answer": payload.get("answer") or "",
                "sources": payload.get("sources") or [],
                "confidence": payload.get("confidence") or 0,
                "marinated": payload.get("marinated") or False,
            }
            self._json(200, response)
        except Exception as exc:  # never let a research error kill the reply path
            self._json(200, {"ok": False, "answer": "", "error": str(exc)})

    def do_OPTIONS(self):
        self.send_response(204)
        self._maybe_cors()
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()


def main():
    port = int(os.environ.get("NEXIE_RESEARCH_PORT", "8765"))
    logfile = os.path.join(os.path.dirname(os.path.abspath(__file__)), "research.log")
    def note(msg):
        try:
            with open(logfile, "a") as fh:
                fh.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
        except Exception:
            pass
    try:
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except Exception as exc:
        note(f"bind FAILED on {port}: {exc!r}")
        raise
    actual = server.server_address[1]
    note(f"bound on port {actual} (requested {port})")
    print(f"nexie-research listening on 127.0.0.1:{actual}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("shutting down", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
