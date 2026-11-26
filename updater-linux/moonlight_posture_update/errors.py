"""Exception classes. Every one maps to a result word and an exit code (same table as the Windows updater)."""

from __future__ import annotations

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_CONFIG = 3          # config / policy / state invalid or unavailable (fail closed)
EXIT_VERIFY = 4          # verification failed, nothing installed
EXIT_INSTALL = 5         # install failed (previous version still / again current)
EXIT_ROLLBACK = 6        # rollback failed or impossible
EXIT_LOCKED = 7          # another instance running
EXIT_DEFER_NET = 8       # rate limit / network problem, retry later


class UpdaterError(Exception):
    """Base class. `result` is the MLPU_RESULT word, `exit_code` the process exit code."""

    result = "failed"
    exit_code = EXIT_INTERNAL

    def __init__(self, message: str, tag: str = "") -> None:
        super().__init__(message)
        self.tag = tag


class ConfigError(UpdaterError):
    result = "failed"
    exit_code = EXIT_CONFIG


class VerifyError(UpdaterError):
    result = "verify_failed"
    exit_code = EXIT_VERIFY


class InstallError(UpdaterError):
    result = "failed"
    exit_code = EXIT_INSTALL


class RollbackError(UpdaterError):
    result = "failed"
    exit_code = EXIT_ROLLBACK


class LockedError(UpdaterError):
    result = "deferred"
    exit_code = EXIT_LOCKED


class NetworkDeferral(UpdaterError):
    """Transient network / rate-limit problem. Nothing is denied, the next run retries."""

    result = "deferred"
    exit_code = EXIT_DEFER_NET


class Deferred(UpdaterError):
    """Not an error: the run stops cleanly and tries again next time (client running, cooling-off, ...)."""

    result = "deferred"
    exit_code = EXIT_OK
