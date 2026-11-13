"""Aufrufe an das ELRD-Backend für die Testwerkzeuge (nur Standardbibliothek).

- `send_raw`: Nachricht über die Debug-Schnittstelle einspielen (Admin-Schlüssel).
- `app_alarms` / `app_ping`: sehen, was die App bekommt (App-Schlüssel).
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request


class BackendError(Exception):
    """Fehler mit verständlichem deutschen Text."""


def _request(url: str, *, headers: dict[str, str], body: dict | None = None, timeout: float = 10) -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method="POST" if body is not None else "GET", headers={
        "Accept": "application/json",
        **({"Content-Type": "application/json"} if body is not None else {}),
        **headers,
    })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            text = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(detail)
            detail = parsed.get("detail") or parsed.get("message") or parsed.get("title") or detail
        except (json.JSONDecodeError, AttributeError):
            pass
        if error.code == 401:
            raise BackendError(f"Schlüssel abgelehnt (401). {detail}".strip()) from None
        if error.code == 404:
            raise BackendError("Nicht gefunden (404) – Organisation angelegt? Debug eingeschaltet?") from None
        raise BackendError(f"Backend antwortet {error.code}: {detail}") from None
    except urllib.error.URLError as error:
        raise BackendError(f"Backend nicht erreichbar: {error.reason}") from None
    except TimeoutError:
        raise BackendError("Backend antwortet nicht (Zeitüberschreitung).") from None
    return json.loads(text or b"{}")


def _base(url: str) -> str:
    url = url.strip().rstrip("/")
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    return url


def send_raw(backend: str, admin_key: str, organisation: str, envelope: dict) -> dict:
    """Spielt die Nachricht direkt in die Schublade ein (ohne Broker)."""
    if not admin_key:
        raise BackendError("Admin-Schlüssel fehlt.")
    url = f"{_base(backend)}/admin/api/debug/{urllib.parse.quote(organisation)}/raw"
    return _request(url, headers={"X-Admin-Key": admin_key}, body={
        "json": json.dumps(envelope, ensure_ascii=False), "via": "direct",
    })


def admin_status(backend: str, admin_key: str) -> dict:
    return _request(f"{_base(backend)}/admin/api/status", headers={"X-Admin-Key": admin_key})


def app_ping(backend: str, app_key: str) -> dict:
    return _request(f"{_base(backend)}/api/v1/ping", headers={"Authorization": f"Bearer {app_key}"})


def app_alarms(backend: str, app_key: str) -> list[dict]:
    """Einsätze so, wie die App sie abruft."""
    return _request(f"{_base(backend)}/api/v1/alarms", headers={"Authorization": f"Bearer {app_key}"}).get("alarms", [])
