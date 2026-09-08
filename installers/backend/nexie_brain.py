#!/usr/bin/env python3
"""
Nexie Brain Service
===================
Pure-Python (stdlib-only, no pip deps) sidecar that owns the app's routing
"brain": deciding how each user message should be handled.  Faithfully ports
three functions that previously lived in Swift:

  * ChatStore.instantReply   -> instant date/time/day answers (fast path)
  * ChatStore.looksLikeResearch -> whether a prompt needs live web info
  * ChatEngine.generateReply -> rule-based offline reply (last-resort fallback)

Exposes a small HTTP API:

    GET  /health                 -> {"ok": true}
    POST /intent  {"query": "...", "style": "jarvis|standard"}

Response:
    {
      "instant_answer":  "",              // non-empty => serve directly, no LLM
      "needs_research":  false,           // true => route through web research
      "reason":          "",              // why research was triggered
      "offline_reply":   ""               // rule-based reply for the no-LLM case
    }

Everything is stdlib.
"""

import json
import os
import re
import threading
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = int(os.environ.get("NEXIE_BRAIN_PORT", "8767"))
AUTH_TOKEN = os.environ.get("NEXIE_AUTH_TOKEN", "")
SERVICE_NAME = "nexie-brain"
SERVICE_VERSION = "1.1.0"
_START_TIME = time.time()


# ---------------------------------------------------------------------------
# Instant reply (faithful port of ChatStore.instantReply(for:))
# ---------------------------------------------------------------------------

def instant_reply(query, style="standard"):
    """Port of instantReply: short, now-oriented date/time/day questions only.

    Uses word-boundary matching for date/time/day (a fix over the original
    substring test, which falsely matched "day" inside "today" or "date"
    inside "update").
    """
    l = query.lower()

    must_have_now = any(w in l for w in ["today", "now", "current"])
    if not must_have_now:
        return ""
    if len(query.split()) > 8:
        return ""

    padded = " " + l + " "
    asks_date = " date " in padded
    asks_time = " time " in padded
    asks_day = " day " in padded

    holiday_words = ["holiday", "valentine", "memorial", "independence", "labor"]
    if any(w in l for w in holiday_words):
        return ""
    if not (asks_date or asks_time or asks_day):
        return ""

    honor = "Sir, " if style == "jarvis" else ""
    now = datetime.now()
    if asks_date and asks_time:
        return "{}It's {}.".format(honor, now.strftime("%A, %B %-d, %Y - %I:%M %p"))
    if asks_date:
        return "{}Today is {}.".format(honor, now.strftime("%A, %B %-d, %Y"))
    if asks_time:
        return "{}It's currently {}.".format(honor, now.strftime("%I:%M %p"))
    if asks_day:
        return "{}Today is {}.".format(honor, now.strftime("%A"))
    return ""


# ---------------------------------------------------------------------------
# Research heuristic (faithful port of ChatStore.looksLikeResearch)
# ---------------------------------------------------------------------------


def needs_research(query):
    """Port of looksLikeResearch.  Returns (bool, reason)."""
    l = query.lower()

    weather_words = ["weather", "forecast", "temperature", "rain", "rainfall",
                     "raining", "sunny", "cloudy", "wind", "humid", "humidity",
                     "snow", "storm", "cold", "hot", "degrees", "forecast"]
    if any(w in l for w in weather_words):
        return True, "weather"

    domains = [".com", ".co", ".au", ".org", ".net", ".io", ".gov", ".edu",
               "www.", "http"]
    if any(d in l for d in domains):
        return True, "domain"

    research_verbs = ["web research", "look it up", "look up", "google it",
                      "search the web", "search for", "find current",
                      "find the latest", "current price", "current price of",
                      "how much does", "how much is", "promo code"]
    if any(v in l for v in research_verbs):
        return True, "research verb"

    commerce_words = ["pricing", "price of", "check price", "cost of",
                      "price tag", "promotion", "promo", "discount",
                      "sale today", "deals", "offer", "in stock", "stockists",
                      "stock now", "availability", "compare", "vs ", "versus",
                      "pros and cons", "specs", "specifications", "requirements",
                      "system requirements", "release date", "launch date",
                      "release", "latest news", "breaking news", "score",
                      "rating", "rankings", "reviews", "review of", "weather",
                      "price", "best price", "cheapest", "where to buy", "buy "]
    if any(w in l for w in commerce_words):
        return True, "commerce"

    current_words = ["current exchange rate", "exchange rate", "stock price",
                     "share price", "crypto price", "bitcoin price",
                     "oil price", "fuel price", "latest version",
                     "newest version", "new release", "current version"]
    if any(w in l for w in current_words):
        return True, "current"

    return False, ""


LOCATION_PHRASES = [
    "my location", "where am i", "where i am", "where am i right now",
    "my position", "current location", "find my location", "my current location",
    "what's my location", "what is my location", "where do i live",
    "which city am i in", "what city am i in", "what country am i in",
    "where am i located", "am i in the philippines", "what time zone am i in",
    "my exact location",
]


def is_location_query(query):
    """True when the user is asking where they are. Punctuation is flattened to
    spaces so 'where am i?' matches, and phrases stay specific enough that
    ordinary chatter never triggers."""
    l = re.sub(r"[^a-z0-9 ]", " ", query.lower())
    return any(phrase in l for phrase in LOCATION_PHRASES)


# ---------------------------------------------------------------------------
# Offline rule-based reply (faithful port of ChatEngine.generateReply(to:))
# ---------------------------------------------------------------------------

def offline_reply(prompt):
    p = prompt.lower()

    if ("hello" in p) or ("hi " in p) or p == "hi" or ("hey" in p):
        return ("Hello! How can I help you today? I can summarize documents, "
                "plan tasks, explain concepts, or explore files on this Mac.")

    if ("who are you" in p) or ("what are you" in p):
        return ("I'm Nexie, a local-first assistant built to run entirely on "
                "your Mac. I keep your data and memory on-device. My model, "
                "tools, and identity all live here - nothing leaves your "
                "machine unless you choose to connect a cloud provider.")

    if "memory" in p:
        return ("I maintain three layers of memory: your identity, pinned "
                "facts, and per-session episodes. At the end of each "
                "conversation I distill what matters, score it by salience, "
                "and store a compact slice so I can recall it later without "
                "bloating my context.")

    if ("offline" in p) or ("privacy" in p):
        return ("Everything runs locally on your Mac. Your chats, files, and "
                "memory never leave the device unless you explicitly connect "
                "a cloud model. I also offer a privacy filter that scrubs "
                "personal data before it goes to any external service.")

    if "plan" in p:
        return ("Here's a simple planning approach: 1) Define the clear end "
                "goal. 2) Break it into small, verifiable steps. 3) Decide "
                "which step to start with. 4) Execute against a checklist and "
                "verify each step before moving on. Want me to draft a "
                "concrete plan for a specific task?")

    if ("summarize" in p) or ("summary" in p):
        return ("I can summarize text, documents, or folders. Open the Files "
                "panel and connect a folder, then paste the content here and "
                "I'll produce a concise summary with the key points.")

    if "help" in p:
        return ("Sure. I can help with: summarizing or explaining text, "
                "planning multi-step tasks, exploring and inspecting your "
                "files, monitoring system health, and managing automations. "
                "Use the sidebar to switch between these workspaces.")

    if ("time" in p) or ("date" in p):
        return "It's {}.".format(datetime.now().strftime("%I:%M %p, %A, %b %-d"))

    if "thank" in p:
        return "You're welcome! Let me know if there's anything else I can do."

    if ("bye" in p) or ("goodbye" in p):
        return "Goodbye! I'll be here in the sidebar whenever you need me."

    if ("file" in p) or ("folder" in p) or ("workspace" in p):
        return ("You can browse files and your on-disk Workspace from the "
                "sidebar. Ask me about a specific file or folder and I'll "
                "inspect it. For a live lookup (like checking a website or "
                "its pricing), turn on 'Deep web research' above the send box "
                "and I'll fetch current sources.")

    if ("website" in p) or ("site" in p) or (".com" in p) or (".au" in p) \
            or ("promotion" in p) or ("terms" in p) or ("pricing" in p):
        return ("I'll check that for you. Turn on 'Deep web research' above "
                "the send box and I'll pull the current page and its exact "
                "terms, then answer directly.")

    return ("I can't answer that accurately from local rules alone, and I "
            "won't guess or drift off-topic.\n\n"
            "To get exactly what you need:\n"
            "- Turn on \"Deep web research\" above the send box for live "
            "topics (pricing, news, a website, terms) - I'll fetch current "
            "sources and answer directly.\n"
            "- Select a text model in the Models tab for open-ended or "
            "complex reasoning.\n"
            "- Or rephrase your question around one clear goal, and I'll "
            "keep the answer focused on that.")


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    request_count = 0

    def log_message(self, fmt, *args):
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
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
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
                    "intent_classification": True,
                    "instant_replies": True,
                    "location_detection": True,
                    "offline_replies": True,
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
        try:
            if path == "/intent":
                query = (payload.get("query") or "").strip()
                style = payload.get("style") or "standard"
                instant = instant_reply(query, style)
                research, reason = needs_research(query) if query else (False, "")
                loc_query = is_location_query(query) if query else False
                fallback = offline_reply(query) if query else ""
                self._json(200, {
                    "ok": True,
                    "instant_answer": instant,
                    "needs_research": research,
                    "reason": reason,
                    "needs_location": loc_query,
                    "offline_reply": fallback,
                })
            else:
                self._json(404, {"ok": False,
                                 "error": {"code": "not_found",
                                           "message": "not found",
                                           "retryable": False,
                                           "request_id": None}})
        except Exception as exc:
            self._json(500, {"ok": False,
                             "error": {"code": "internal_error",
                                       "message": str(exc),
                                       "retryable": True,
                                       "request_id": None}})

    def do_OPTIONS(self):
        self.send_response(204)
        self._maybe_cors()
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()


def main():
    port = DEFAULT_PORT
    logfile = os.path.join(os.path.dirname(os.path.abspath(__file__)), "brain.log")

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
    print(f"nexie-brain listening on 127.0.0.1:{actual}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("shutting down", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()