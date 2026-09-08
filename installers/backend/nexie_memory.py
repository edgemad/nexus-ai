#!/usr/bin/env python3
"""
Nexie Memory Service
====================
Pure-Python (stdlib-only, no pip deps) sidecar that owns the agent's persistent
knowledge base (skills, knowledge entries, and long-term memories).  Faithfully
ports every function from the Swift KnowledgeStore.swift, preserving the exact
JSON format (reference-date doubles, uppercase UUIDs, omitted nils) so the
SwiftUI views read the same knowledge.json interchangeably.

Exposes a small HTTP API:

    GET  /health                   -> {"ok": true}
    POST /context  {"query": "..."} -> {"context": str, "matches": [...]}
    POST /search   {"query": "..."} -> {"matches": [...]}
    POST /learn    {"user_text": "...", "assistant_text": "..."} -> {"new_items": [...], "count": N}
    GET  /items                    -> {"items": [...]}
    POST /add      {"item": {...}}  -> {"item": {...}}
    POST /delete   {"id": "..."}   -> {"ok": true}
    POST /update   {"item": {...}}  -> {"item": {...}}

Everything is stdlib.  Date encoding matches Swift JSONEncoder's default
(timeIntervalSinceReferenceDate = seconds since 2001-01-01 00:00:00 UTC).
"""

import json
import os
import re
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime, timezone

# Seconds between Unix epoch (1970-01-01) and Swift reference epoch (2001-01-01).
_SWIFT_EPOCH_OFFSET = 978307200.0

DEFAULT_PORT = int(os.environ.get("NEXIE_MEMORY_PORT", "8766"))
AUTH_TOKEN = os.environ.get("NEXIE_AUTH_TOKEN", "")
SERVICE_NAME = "nexie-memory"
SERVICE_VERSION = "1.1.0"
_START_TIME = time.time()
WORKSPACE_ROOT = os.environ.get(
    "NEXIE_WORKSPACE_ROOT",
    os.path.expanduser("~/NexusAI Workspace"),
)
KNOWLEDGE_FILE = os.path.join(WORKSPACE_ROOT, "knowledge.json")
MEMORY_CAP = 80  # max memories before oldest are trimmed


# ---------------------------------------------------------------------------
# Date helpers
# ---------------------------------------------------------------------------

def swift_now():
    """Current time as a Swift reference-date double."""
    return time.time() - _SWIFT_EPOCH_OFFSET


def swift_to_unix(d):
    """Convert a Swift reference-date double to a Unix timestamp."""
    return d + _SWIFT_EPOCH_OFFSET


def swift_to_iso(d):
    """Convert a Swift reference-date double to an ISO-8601 string."""
    try:
        return datetime.fromtimestamp(d, tz=timezone.utc).isoformat()
    except Exception:
        return str(d)


# ---------------------------------------------------------------------------
# Persistence (atomic read/write of knowledge.json)
# ---------------------------------------------------------------------------

def load_items():
    """Load all items from knowledge.json.  Returns [] on any error."""
    if not os.path.exists(KNOWLEDGE_FILE):
        return []
    try:
        with open(KNOWLEDGE_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return []


def save_items(items):
    """Atomically write items to knowledge.json (same format as Swift)."""
    try:
        tmp = KNOWLEDGE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(items, fh, indent=2, ensure_ascii=False, sort_keys=True)
        os.replace(tmp, KNOWLEDGE_FILE)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# New item factory (matches Swift KnowledgeItem init defaults)
# ---------------------------------------------------------------------------

def new_item(item_type, title, content, tags=None, source="chat reflection",
             memory_kind=None, skill_description=None, topic=None):
    """Create a dict matching Swift KnowledgeItem's JSON shape."""
    now = swift_now()
    item = {
        "id": str(uuid.uuid4()).upper(),
        "type": item_type,
        "title": title,
        "content": content,
        "tags": tags or [],
        "source": source,
        "createdAt": now,
        "updatedAt": now,
    }
    if memory_kind:
        item["memoryKind"] = memory_kind
    if skill_description:
        item["skillDescription"] = skill_description
    if topic:
        item["topic"] = topic
    return item


# ---------------------------------------------------------------------------
# Relevance scoring (faithful port of KnowledgeItem.relevance(to:))
# ---------------------------------------------------------------------------

def relevance(item, query):
    """Token-overlap relevance score.  Higher = more relevant."""
    haystack = " ".join([
        item.get("title", ""),
        item.get("content", ""),
        " ".join(item.get("tags", [])),
        item.get("skillDescription") or "",
        item.get("topic") or "",
    ]).lower()
    tokens = [w for w in re.split(r"[^A-Za-z0-9]", query.lower()) if len(w) > 2]
    if not tokens:
        return 0.0
    unique = set(tokens)
    matched = sum(1 for t in unique if t in haystack)
    return matched / len(unique)


# ---------------------------------------------------------------------------
# Search (faithful port of KnowledgeStore.search)
# ---------------------------------------------------------------------------

def search(query, items):
    """Score every item, keep top 6 with score > 0."""
    q = query.strip()
    if not q:
        return []
    scored = [(item, relevance(item, q)) for item in items]
    scored = [(i, s) for i, s in scored if s > 0]
    scored.sort(key=lambda x: -x[1])
    return [item for item, _ in scored[:6]]


# ---------------------------------------------------------------------------
# Context for prompt (faithful port of KnowledgeStore.contextForPrompt)
# ---------------------------------------------------------------------------

def build_context(query, items):
    """Build the context block to inject into an assistant prompt."""
    relevant = search(query, items)
    remembered = [i for i in relevant if i.get("type") == "Memory"]
    learned = [i for i in relevant if i.get("type") != "Memory"]
    blocks = []
    if remembered:
        lines = [
            f"- [{(i.get('memoryKind') or 'memory').lower()}] {i['content']}"
            for i in remembered
        ]
        blocks.append("Long-term memories about the user:\n" + "\n".join(lines))
    if learned:
        lines = []
        for i in learned:
            s = f"\u2022 {i['title']}: {i['content']}"
            desc = i.get("skillDescription") or ""
            if desc:
                s += f" (apply when: {desc})"
            lines.append(s)
        blocks.append("Relevant skills and knowledge to apply:\n" + "\n".join(lines))
    return "\n\n".join(blocks)


# ---------------------------------------------------------------------------
# Learn from conversation (faithful port of learnFromConversation)
# ---------------------------------------------------------------------------

_MEMORY_KEYS = {
    "not available", "in conjunction", "cannot be combined", "cannot be used",
    "not be used", "not valid", "exclud", "while stocks last",
    "normal retail quantit", "new orders", "100% payment", "full payment",
    "payment at the", "based on the", "recommended retail", "retail price",
    "r.r.p", "rrp", "standard terms", "gift card", "does not apply",
    "not applicable", "clearance", "subject to availability", "quantities only",
}


def classify_line(text):
    """Classify a short text line into a MemoryKind."""
    lower = text.lower()
    if any(k in lower for k in ("prefer", "like to", "would rather")):
        return "Preference"
    if any(k in lower for k in ("learn", "can ", "i know")):
        return "Skill"
    if any(k in lower for k in ("don't", "should not", "avoid")):
        return "Correction"
    return "Fact"


def learn_from_conversation(user_text, assistant_text):
    """Port of KnowledgeStore.learnFromConversation.  Returns list of new items added."""
    items = load_items()
    existing_memory_contents = {
        (i.get("content") or "").lower()
        for i in items
        if i.get("type") == "Memory"
    }
    extracted = []
    user = user_text.strip()
    if user and len(user) <= 220:
        if user.lower() not in existing_memory_contents:
            extracted.append(new_item("Memory", "Recall", user,
                                      source="chat reflection", memory_kind="Fact"))

    for line in assistant_text.split("\n"):
        s = line.strip()
        if not s or len(s) >= 140 or " " not in s:
            continue
        lower = s.lower()
        if lower in existing_memory_contents:
            continue
        kind = classify_line(s)
        extracted.append(new_item("Memory", "Memory", s,
                                  source="chat reflection", memory_kind=kind))
        existing_memory_contents.add(lower)

    if not extracted:
        return []

    items.extend(extracted)

    # Trim oldest memories if over cap.
    memories = [i for i in items if i.get("type") == "Memory"]
    if len(memories) > MEMORY_CAP:
        excess = len(memories) - MEMORY_CAP
        memories.sort(key=lambda i: i.get("createdAt", 0))
        trim_ids = {m["id"] for m in memories[:excess]}
        items = [i for i in items if i.get("id") not in trim_ids]

    save_items(items)
    return extracted


# ---------------------------------------------------------------------------
# Item mutations
# ---------------------------------------------------------------------------

def add_item(item_dict):
    items = load_items()
    # Fill in missing fields with defaults.
    item_dict.setdefault("id", str(uuid.uuid4()).upper())
    item_dict.setdefault("type", "Memory")
    item_dict.setdefault("title", "")
    item_dict.setdefault("content", "")
    item_dict.setdefault("tags", [])
    item_dict.setdefault("source", "manual")
    item_dict.setdefault("createdAt", swift_now())
    item_dict["updatedAt"] = swift_now()
    items.insert(0, item_dict)
    save_items(items)
    return item_dict


def delete_item(item_id):
    items = load_items()
    items = [i for i in items if i.get("id") != item_id]
    save_items(items)


def update_item(item_dict):
    items = load_items()
    target_id = item_dict.get("id")
    for i, item in enumerate(items):
        if item.get("id") == target_id:
            item_dict["updatedAt"] = swift_now()
            items[i] = item_dict
            save_items(items)
            return item_dict
    return None


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
                    "context_build": True,
                    "semantic_search": True,
                    "learn": True,
                    "memory_add_delete_update": True,
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
                "memory_count": len(load_items()),
            })
        elif path == "/items":
            if not self._authorized():
                return self._unauthorized()
            self._json(200, {"ok": True, "items": load_items()})
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
            if path == "/context":
                query = payload.get("query", "")
                items = load_items()
                ctx = build_context(query, items)
                matches = search(query, items)
                self._json(200, {"ok": True, "context": ctx, "matches": matches})
            elif path == "/search":
                query = payload.get("query", "")
                items = load_items()
                matches = search(query, items)
                self._json(200, {"ok": True, "matches": matches})
            elif path == "/learn":
                user_text = payload.get("user_text", "")
                assistant_text = payload.get("assistant_text", "")
                new_items = learn_from_conversation(user_text, assistant_text)
                self._json(200, {"ok": True, "new_items": new_items, "count": len(new_items)})
            elif path == "/add":
                item = payload.get("item", {})
                saved = add_item(item)
                self._json(200, {"ok": True, "item": saved})
            elif path == "/delete":
                item_id = payload.get("id", "")
                delete_item(item_id)
                self._json(200, {"ok": True})
            elif path == "/update":
                item = payload.get("item", {})
                updated = update_item(item)
                if updated:
                    self._json(200, {"ok": True, "item": updated})
                else:
                    self._json(404, {"ok": False,
                                     "error": {"code": "not_found",
                                               "message": "item not found",
                                               "retryable": False,
                                               "request_id": None}})
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
    logfile = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory.log")

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
    items = load_items()
    note(f"loaded {len(items)} items from {KNOWLEDGE_FILE}")
    print(f"nexie-memory listening on 127.0.0.1:{actual}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("shutting down", flush=True)
        server.shutdown()


if __name__ == "__main__":
    main()
