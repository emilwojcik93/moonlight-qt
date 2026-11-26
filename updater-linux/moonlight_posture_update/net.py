"""Anonymous GitHub access: no Authorization header is ever sent. HTTPS only, every redirect hop checked against a
host allow-list, size caps, truncation detection, deadlines, ETag / conditional requests, rate-limit awareness.
"""

from __future__ import annotations

import http.client
import json
import os
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, Optional, Tuple

from . import fsio
from .errors import NetworkDeferral, VerifyError

USER_AGENT = "moonlight-posture-updater/1"
MAX_API_BYTES = 4 * 1024 * 1024
MAX_REDIRECTS = 4
ALLOWED_HOSTS = frozenset({
    "github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
})


@dataclass
class HttpSettings:
    """Endpoints are constants of the code. Tests build their own instance in memory (loopback http)."""
    api_base: str = "https://api.github.com"
    download_base: str = "https://github.com"
    allowed_hosts: frozenset = ALLOWED_HOSTS
    require_https: bool = True
    use_env_proxy: bool = True
    api_timeout: float = 60.0
    small_timeout: float = 120.0
    big_timeout: float = 600.0       # whole-download deadline for the AppImage
    socket_timeout: float = 30.0


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401 - urllib API
        return None


class Response:
    def __init__(self, status: int, headers: Dict[str, str], body: bytes = b"") -> None:
        self.status = status
        self.headers = headers
        self.body = body


def _lower(h) -> Dict[str, str]:
    return {k.lower(): v for k, v in h.items()}


class Http:
    def __init__(self, settings: HttpSettings) -> None:
        self.s = settings
        handlers = [_NoRedirect()]
        if not settings.use_env_proxy:
            handlers.append(urllib.request.ProxyHandler({}))
        self.opener = urllib.request.build_opener(*handlers)

    # ---- URL checks -----------------------------------------------------------------------------------------
    def check_url(self, url: str) -> None:
        u = urllib.parse.urlsplit(url)
        if self.s.require_https and u.scheme != "https":
            raise VerifyError("refusing non-https url")
        if u.scheme not in ("https", "http"):
            raise VerifyError("refusing url scheme")
        if u.username or u.password:
            raise VerifyError("refusing url with credentials")
        host = (u.hostname or "").lower()
        if host not in self.s.allowed_hosts:
            raise VerifyError("host not allowed: %s" % host[:60])
        if self.s.require_https and u.port not in (None, 443):
            raise VerifyError("port not allowed")

    # ---- one request, redirects followed manually -----------------------------------------------------------
    def _open(self, url: str, headers: Dict[str, str], timeout: float):
        for _hop in range(MAX_REDIRECTS + 1):
            self.check_url(url)
            req = urllib.request.Request(url, headers=dict(headers, **{"User-Agent": USER_AGENT}))
            try:
                resp = self.opener.open(req, timeout=min(timeout, self.s.socket_timeout))
                return resp, url
            except urllib.error.HTTPError as e:
                if e.code in (301, 302, 303, 307, 308):
                    loc = e.headers.get("Location")
                    e.close()
                    if not loc:
                        raise NetworkDeferral("redirect without location")
                    url = urllib.parse.urljoin(url, loc)
                    continue
                if e.code == 304:
                    return e, url          # HTTPError doubles as a response object
                self._raise_for_status(e.code, _lower(e.headers))
                raise  # not reached
            except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError,
                    http.client.HTTPException, OSError) as e:
                raise NetworkDeferral("network error: %s" % (getattr(e, "reason", e)))
        raise NetworkDeferral("too many redirects")

    @staticmethod
    def _raise_for_status(code: int, h: Dict[str, str]) -> None:
        if code in (403, 429) and (h.get("x-ratelimit-remaining") == "0" or "retry-after" in h):
            raise NetworkDeferral("github rate limit reached (retry-after=%s)" % h.get("retry-after", "?"))
        raise NetworkDeferral("http status %d" % code)

    # ---- API -------------------------------------------------------------------------------------------------
    def get_json(self, path: str, etag: Optional[str] = None) -> Tuple[int, Any, Dict[str, str]]:
        """Returns (status, parsed-json-or-None, headers). 304 -> (304, None, headers)."""
        url = self.s.api_base + path
        hdrs = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        if etag:
            hdrs["If-None-Match"] = etag
        resp, _ = self._open(url, hdrs, self.s.api_timeout)
        try:
            h = _lower(resp.headers)
            status = resp.status if hasattr(resp, "status") else resp.code
            if status == 304:
                return 304, None, h
            if status != 200:
                raise NetworkDeferral("unexpected http status %d" % status)
            cl = h.get("content-length")
            if cl and cl.isdigit() and int(cl) > MAX_API_BYTES:
                raise VerifyError("api response too large")
            try:
                raw = resp.read(MAX_API_BYTES + 1)
            except (http.client.HTTPException, OSError) as e:
                raise NetworkDeferral("api read failed: %s" % e)
            if len(raw) > MAX_API_BYTES:
                raise VerifyError("api response too large")
            try:
                return 200, json.loads(raw.decode("utf-8")), h
            except ValueError:
                raise VerifyError("api response is not valid json")
        finally:
            resp.close()

    # ---- downloads ---------------------------------------------------------------------------------------------
    def asset_url(self, repo: str, tag: str, name: str) -> str:
        return "%s/%s/releases/download/%s/%s" % (
            self.s.download_base, repo, urllib.parse.quote(tag, safe=""), urllib.parse.quote(name, safe=""))

    def download(self, url: str, dest: str, max_bytes: int, expected_size: Optional[int] = None,
                 timeout: Optional[float] = None) -> Tuple[int, Dict[str, str]]:
        """Stream `url` to `dest` (created 0600, O_EXCL). Returns (size, headers). On any failure `dest` is removed.

        Oversize and size-mismatch are VerifyError (content problem); connection trouble, truncation and bad
        status are NetworkDeferral (transient)."""
        deadline = time.monotonic() + (timeout if timeout is not None else self.s.small_timeout)
        resp, _ = self._open(url, {"Accept": "application/octet-stream"}, self.s.small_timeout)
        fd = -1
        try:
            status = resp.status if hasattr(resp, "status") else resp.code
            if status != 200:
                raise NetworkDeferral("unexpected http status %d" % status)
            h = _lower(resp.headers)
            cl = h.get("content-length")
            clen = int(cl) if cl and cl.isdigit() else None
            if clen is not None and clen > max_bytes:
                raise VerifyError("asset larger than the cap (%d > %d)" % (clen, max_bytes))
            if expected_size is not None and clen is not None and clen != expected_size:
                raise VerifyError("content-length differs from the expected size")
            fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            total = 0
            with os.fdopen(fd, "wb") as f:
                fd = -1
                while True:
                    if time.monotonic() > deadline:
                        raise NetworkDeferral("download deadline exceeded")
                    try:
                        chunk = resp.read(256 * 1024)
                    except (http.client.HTTPException, OSError) as e:
                        raise NetworkDeferral("download interrupted: %s" % e)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > max_bytes:
                        raise VerifyError("asset larger than the cap")
                    fsio.write_chunk(f, chunk)
                f.flush()
            if clen is not None and total != clen:
                raise NetworkDeferral("download truncated (%d of %d bytes)" % (total, clen))
            if expected_size is not None and total != expected_size:
                raise VerifyError("size differs from the expected size (%d != %d)" % (total, expected_size))
            return total, h
        except BaseException:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(dest)
            except OSError:
                pass
            raise
        finally:
            resp.close()
