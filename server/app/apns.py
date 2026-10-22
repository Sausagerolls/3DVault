"""Apple Push Notification service: alerts when prints end, and Live Activity updates.

Uses token-based authentication with a .p8 key from the owner's Apple developer account,
uploaded in web Settings and stored in the data folder (never in the repo). Requests go
over HTTP/2 to the sandbox host for development builds and the production host otherwise.
"""

import base64
import json
import logging
import threading
import time

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from .config import settings

log = logging.getLogger("vault.apns")

BUNDLE_ID = "com.3dvault.mac"
TEAM_ID = "J4UJD4Z33J"
HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}


def key_path():
    return settings.data_dir / "apns" / "key.p8"


def config_path():
    return settings.data_dir / "apns" / "config.json"


def configured() -> bool:
    return key_path().exists() and config_path().exists()


def save_key(p8: bytes, key_id: str, team_id: str = TEAM_ID) -> None:
    serialization.load_pem_private_key(p8, password=None)  # refuse anything that isn't a key
    d = key_path().parent
    d.mkdir(parents=True, exist_ok=True)
    key_path().write_bytes(p8)
    key_path().chmod(0o600)
    config_path().write_text(json.dumps({"key_id": key_id.strip(), "team_id": team_id.strip()}))
    sender.reset()


def remove_key() -> None:
    key_path().unlink(missing_ok=True)
    config_path().unlink(missing_ok=True)
    sender.reset()


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def make_jwt(p8: bytes, key_id: str, team_id: str, now: int | None = None) -> str:
    """ES256 provider token. Apple accepts one for up to an hour; it is refreshed every 50 minutes."""
    key = serialization.load_pem_private_key(p8, password=None)
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id}).encode())
    claims = _b64(json.dumps({"iss": team_id, "iat": now or int(time.time())}).encode())
    signing_input = f"{header}.{claims}".encode()
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{header}.{claims}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


class Sender:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jwt = ""
        self._jwt_at = 0.0
        self._client: httpx.Client | None = None

    def reset(self) -> None:
        with self._lock:
            self._jwt, self._jwt_at = "", 0.0

    def _token(self) -> str:
        with self._lock:
            if not self._jwt or time.time() - self._jwt_at > 50 * 60:
                cfg = json.loads(config_path().read_text())
                self._jwt = make_jwt(key_path().read_bytes(), cfg["key_id"], cfg.get("team_id") or TEAM_ID)
                self._jwt_at = time.time()
            return self._jwt

    def send(self, token: str, environment: str, payload: dict, push_type: str = "alert",
             topic: str = BUNDLE_ID, priority: int = 10, collapse_id: str | None = None) -> int:
        """Send one push. Returns the HTTP status; 410 means the token is no longer valid."""
        if not configured():
            return 0
        if self._client is None:
            self._client = httpx.Client(http2=True, timeout=15)
        headers = {
            "authorization": f"bearer {self._token()}",
            "apns-topic": topic,
            "apns-push-type": push_type,
            "apns-priority": str(priority),
        }
        if collapse_id:
            headers["apns-collapse-id"] = collapse_id
        url = f"{HOSTS.get(environment, HOSTS['production'])}/3/device/{token}"
        try:
            r = self._client.post(url, headers=headers, content=json.dumps(payload).encode())
        except httpx.HTTPError as e:
            log.warning("push failed: %s", e)
            return -1
        if r.status_code != 200:
            log.warning("push %s returned %s: %s", push_type, r.status_code, r.text[:200])
        return r.status_code


sender = Sender()
