"""Optional alerts when prints end, sent by this server to a service its owner already uses:
ntfy, Gotify, Pushover, a Discord webhook, or any webhook (such as Home Assistant).

The iPhone app doesn't need this: it tracks prints it knows about with a Live Activity and
local notifications. This is for owners who want failures reported the moment they happen.
"""

import json
import logging
from concurrent.futures import ThreadPoolExecutor

import httpx

from .db import session_scope
from .models import PrintJob, Setting
from .secretbox import seal, unseal

log = logging.getLogger("vault.notify")

KEY = "notifier"
KINDS = ("ntfy", "gotify", "pushover", "discord", "webhook")
EVENTS = ("started", "finished", "failed", "paused")

_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="notify")


def _load() -> dict:
    with session_scope() as db:
        row = db.get(Setting, KEY)
        return json.loads(row.value) if row and row.value else {}


def public_config() -> dict:
    cfg = _load()
    return {
        "kind": cfg.get("kind", ""), "url": cfg.get("url", ""), "topic": cfg.get("topic", ""),
        "user_key": cfg.get("user_key", ""), "has_secret": bool(cfg.get("secret")),
        "events": cfg.get("events", ["finished", "failed"]),
    }


def save_config(new: dict) -> None:
    kind = new.get("kind") or ""
    if kind and kind not in KINDS:
        raise ValueError("Unknown notification service")
    old = _load()
    cfg = {
        "kind": kind,
        "url": (new.get("url") or "").strip().rstrip("/"),
        "topic": (new.get("topic") or "").strip(),
        "user_key": (new.get("user_key") or "").strip(),
        "events": [e for e in new.get("events") or [] if e in EVENTS],
        "secret": seal(new["secret"]) if new.get("secret") is not None else old.get("secret", ""),
    }
    if kind in ("ntfy", "gotify", "discord", "webhook") and not cfg["url"].startswith(("http://", "https://")):
        raise ValueError("Enter the full address, starting with http:// or https://")
    if kind == "ntfy" and not cfg["topic"]:
        raise ValueError("Enter the ntfy topic")
    if kind == "pushover" and not (cfg["user_key"] and cfg["secret"]):
        raise ValueError("Enter the Pushover user key and app token")
    with session_scope() as db:
        db.merge(Setting(key=KEY, value=json.dumps(cfg)))


def send(title: str, message: str, priority: str = "default", raise_errors: bool = False, extra: dict | None = None) -> None:
    cfg = _load()
    kind = cfg.get("kind")
    if not kind:
        if raise_errors:
            raise ValueError("No notification service is set up")
        return
    secret = unseal(cfg.get("secret", ""))
    url = cfg.get("url", "")
    high = priority == "high"
    try:
        with httpx.Client(timeout=15) as c:
            if kind == "ntfy":
                headers = {"Title": title, "Priority": "high" if high else "default", "Tags": "printer"}
                if secret:
                    headers["Authorization"] = f"Bearer {secret}"
                r = c.post(f"{url}/{cfg['topic']}", content=message.encode(), headers=headers)
            elif kind == "gotify":
                r = c.post(f"{url}/message", params={"token": secret}, json={"title": title, "message": message, "priority": 8 if high else 5})
            elif kind == "pushover":
                r = c.post("https://api.pushover.net/1/messages.json", data={
                    "token": secret, "user": cfg["user_key"], "title": title, "message": message, "priority": 1 if high else 0})
            elif kind == "discord":
                r = c.post(url, json={"content": f"**{title}**\n{message}"})
            else:
                headers = {"Authorization": f"Bearer {secret}"} if secret else {}
                r = c.post(url, json={"title": title, "message": message, **(extra or {})}, headers=headers)
            r.raise_for_status()
    except Exception as e:
        log.warning("notification via %s failed: %s", kind, e)
        if raise_errors:
            raise


def job_event(job: PrintJob, event: str) -> None:
    """Called by the print manager when a job starts, pauses or ends."""
    events = _load().get("events", ["finished", "failed"])
    if event not in events:
        return
    printer = job.machine.name if job.machine else "the printer"
    title, message, priority = {
        "started": ("Print started", f"{job.model_name} started on {printer}.", "default"),
        "finished": ("Print finished", f"{job.model_name} is done on {printer}. Clear the bed for the next print.", "default"),
        "failed": ("Print failed", f"{job.model_name} stopped on {printer}. {job.error}".strip(), "high"),
        "paused": ("Print paused", f"{job.model_name} is paused on {printer}.", "high"),
    }[event]
    extra = {"event": event, "job_id": job.id, "model_id": job.model_id, "printer": printer, "progress": job.progress}
    _pool.submit(send, title, message, priority, False, extra)
