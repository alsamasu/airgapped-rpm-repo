"""
Update Calculator

Main module for computing available package updates by comparing
installed packages from host manifests against mirrored repository content.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from .rpm_utils import format_evr, is_update_available

logger = logging.getLogger(__name__)


@dataclass
class PackageUpdate:
    """Represents an available package update."""

    name: str
    arch: str
    channel: str
    installed_epoch: str
    installed_version: str
    installed_release: str
    available_epoch: str
    available_version: str
    available_release: str

    @property
    def installed_evr(self) -> str:
        """Return installed EVR string."""
        return format_evr(
            self.installed_epoch,
            self.installed_version,
            self.installed_release,
        )

    @property
    def available_evr(self) -> str:
        """Return available EVR string."""
        return format_evr(
            self.available_epoch,
            self.available_version,
            self.available_release,
        )

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary."""
        return {
            "name": self.name,
            "arch": self.arch,
            "channel": self.channel,
            "installed": {
                "epoch": self.installed_epoch,
                "version": self.installed_version,
                "release": self.installed_release,
            },
            "available": {
                "epoch": self.available_epoch,
                "version": self.available_version,
                "release": self.available_release,
            },
        }


@dataclass
class UpdateResult:
    """Results of update computation for a single host."""

    host_id: str
    profile: str
    os_id: str
    os_version: str
    computed_at: str
    updates: list[PackageUpdate] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def update_count(self) -> int:
        """Return number of available updates."""
        return len(self.updates)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary."""
        return {
            "host_id": self.host_id,
            "profile": self.profile,
            "os_id": self.os_id,
            "os_version": self.os_version,
            "computed_at": self.computed_at,
            "update_count": self.update_count,
            "updates": [u.to_dict() for u in self.updates],
            "errors": self.errors,
        }

    def to_json(self, indent: int = 2) -> str:
        """Convert to JSON string."""
        return json.dumps(self.to_dict(), indent=indent)


class UpdateCalculator:
    """
    Computes available package updates for hosts.

    Compares installed packages from host manifests against available
    packages in mirrored repositories.
    """

    def __init__(
        self,
        mirror_dir: str | Path,
        manifests_dir: str | Path,
    ):
        """
        Initialize the update calculator.

        Args:
            mirror_dir: Path to mirrored repository content
            manifests_dir: Path to host manifests directory
        """
        self.mirror_dir = Path(mirror_dir)
        self.manifests_dir = Path(manifests_dir)
        self._repo_cache: dict[str, dict[str, dict]] = {}

    def get_profile_for_os(self, os_id: str, os_version: str) -> str:
        """
        Determine the repository profile for an OS.

        Args:
            os_id: OS identifier (e.g., "rhel", "centos")
            os_version: OS version (e.g., "8.10", "9.6")

        Returns:
            Profile name (e.g., "rhel8", "rhel9")
        """
        major_version = os_version.split(".")[0]

        if os_id in ("rhel", "centos", "rocky", "almalinux"):
            return f"rhel{major_version}"

        # Default fallback
        return f"rhel{major_version}"

    def load_manifest(self, host_id: str) -> dict | None:
        """
        Load a host manifest.

        Args:
            host_id: Host identifier

        Returns:
            Manifest data or None if not found
        """
        manifest_dir = self.manifests_dir / "processed" / host_id / "latest"
        manifest_file = manifest_dir / "manifest.json"

        if not manifest_file.exists():
            logger.warning(f"Manifest not found for host: {host_id}")
            return None

        with open(manifest_file) as f:
            return json.load(f)

    def load_repo_packages(
        self, profile: str, arch: str, channel: str
    ) -> dict[str, dict]:
        """
        Load available packages from a repository.

        Args:
            profile: Repository profile (e.g., "rhel9")
            arch: Architecture (e.g., "x86_64")
            channel: Channel name (e.g., "baseos")

        Returns:
            Dict mapping package key (name.arch) to package info
        """
        cache_key = f"{profile}/{arch}/{channel}"

        if cache_key in self._repo_cache:
            return self._repo_cache[cache_key]

        repo_path = self.mirror_dir / profile / arch / channel
        cache_file = repo_path / ".package_cache.json"

        if cache_file.exists():
            with open(cache_file) as f:
                packages = json.load(f)
                self._repo_cache[cache_key] = packages
                return packages

        # No cache available
        logger.warning(f"No package cache for {cache_key}")
        return {}

    def compute_updates_for_host(self, host_id: str) -> UpdateResult:
        """
        Compute available updates for a specific host.

        Args:
            host_id: Host identifier

        Returns:
            UpdateResult with available updates
        """
        now = datetime.utcnow().isoformat() + "Z"

        manifest = self.load_manifest(host_id)
        if not manifest:
            return UpdateResult(
                host_id=host_id,
                profile="unknown",
                os_id="unknown",
                os_version="unknown",
                computed_at=now,
                errors=[f"Manifest not found for host: {host_id}"],
            )

        os_id = manifest.get("os_release", {}).get("id", "unknown")
        os_version = manifest.get("os_release", {}).get("version", "unknown")
        profile = self.get_profile_for_os(os_id, os_version)

        result = UpdateResult(
            host_id=host_id,
            profile=profile,
            os_id=os_id,
            os_version=os_version,
            computed_at=now,
        )

        installed_packages = manifest.get("packages", [])
        if not installed_packages:
            result.errors.append("No packages found in manifest")
            return result

        # Check each channel
        for channel in ["baseos", "appstream"]:
            repo_packages = self.load_repo_packages(
                profile, "x86_64", channel
            )

            if not repo_packages:
                continue

            for pkg in installed_packages:
                name = pkg.get("name")
                arch = pkg.get("arch")

                if not name or not arch:
                    continue

                key = f"{name}.{arch}"
                available = repo_packages.get(key)

                if not available:
                    continue

                installed_info = {
                    "epoch": pkg.get("epoch", "0"),
                    "version": pkg.get("version", "0"),
                    "release": pkg.get("release", "0"),
                }

                available_info = {
                    "epoch": available.get("epoch", "0"),
                    "version": available.get("version", "0"),
                    "release": available.get("release", "0"),
                }

                if is_update_available(installed_info, available_info):
                    update = PackageUpdate(
                        name=name,
                        arch=arch,
                        channel=channel,
                        installed_epoch=str(installed_info["epoch"]),
                        installed_version=installed_info["version"],
                        installed_release=installed_info["release"],
                        available_epoch=str(available_info["epoch"]),
                        available_version=available_info["version"],
                        available_release=available_info["release"],
                    )
                    result.updates.append(update)

        return result

    def compute_all_updates(self) -> Iterator[UpdateResult]:
        """
        Compute updates for all hosts with manifests.

        Yields:
            UpdateResult for each host
        """
        processed_dir = self.manifests_dir / "processed"

        if not processed_dir.exists():
            logger.warning("No processed manifests directory")
            return

        for host_dir in processed_dir.iterdir():
            if host_dir.is_dir():
                host_id = host_dir.name
                yield self.compute_updates_for_host(host_id)

    def generate_summary(
        self, results: list[UpdateResult]
    ) -> dict[str, Any]:
        """
        Generate a summary of update computation results.

        Args:
            results: List of UpdateResult objects

        Returns:
            Summary dictionary
        """
        total_updates = sum(r.update_count for r in results)
        hosts_with_updates = sum(1 for r in results if r.update_count > 0)

        return {
            "generated_at": datetime.utcnow().isoformat() + "Z",
            "total_hosts": len(results),
            "hosts_with_updates": hosts_with_updates,
            "total_updates": total_updates,
            "hosts": [
                {
                    "host_id": r.host_id,
                    "profile": r.profile,
                    "update_count": r.update_count,
                }
                for r in results
            ],
        }
