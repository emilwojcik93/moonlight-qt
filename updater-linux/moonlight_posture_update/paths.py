"""All filesystem locations, derived from one home directory (tests pass a temp dir)."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Paths:
    home: str

    @property
    def config_dir(self) -> str:
        return os.path.join(self.home, ".config", "moonlight-posture-updater")

    @property
    def policy_file(self) -> str:
        return os.path.join(self.config_dir, "policy.json")

    @property
    def state_dir(self) -> str:
        return os.path.join(self.home, ".local", "state", "moonlight-posture-updater")

    @property
    def state_file(self) -> str:
        return os.path.join(self.state_dir, "state.json")

    @property
    def log_file(self) -> str:
        return os.path.join(self.state_dir, "log")

    @property
    def lock_file(self) -> str:
        return os.path.join(self.state_dir, "lock")

    @property
    def cache_dir(self) -> str:
        return os.path.join(self.state_dir, "cache")

    @property
    def runs_dir(self) -> str:
        return os.path.join(self.state_dir, "runs")

    @property
    def gh_dir(self) -> str:
        return os.path.join(self.state_dir, "gh")

    @property
    def opt_dir(self) -> str:
        return os.path.join(self.home, ".local", "opt", "moonlight-posture")

    @property
    def current_link(self) -> str:
        return os.path.join(self.opt_dir, "current")

    @property
    def bin_dir(self) -> str:
        return os.path.join(self.home, ".local", "bin")

    @property
    def launcher_dir(self) -> str:
        """Real launcher lives inside the updater's writable tree; ~/.local/bin only holds symlinks made by install.sh."""
        return os.path.join(self.opt_dir, "launcher")

    @property
    def launcher(self) -> str:
        return os.path.join(self.launcher_dir, "moonlight-posture")

    @property
    def launcher_link(self) -> str:
        return os.path.join(self.bin_dir, "moonlight-posture")

    @property
    def apps_dir(self) -> str:
        return os.path.join(self.home, ".local", "share", "applications")

    @property
    def desktop_file(self) -> str:
        return os.path.join(self.apps_dir, "moonlight-posture.desktop")
