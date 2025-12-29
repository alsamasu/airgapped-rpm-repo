"""
RPM Utilities

Provides utilities for parsing and comparing RPM package versions.
Handles NEVRA (Name-Epoch-Version-Release-Arch) format and version comparison.
"""

import re
from dataclasses import dataclass
from functools import total_ordering
from typing import Optional, Tuple


@total_ordering
@dataclass
class RPMVersion:
    """
    Represents an RPM package version with NEVRA components.

    Attributes:
        name: Package name
        epoch: Package epoch (default: 0)
        version: Package version string
        release: Package release string
        arch: Package architecture
    """

    name: str
    epoch: int
    version: str
    release: str
    arch: str

    def __post_init__(self) -> None:
        """Normalize epoch to integer."""
        if isinstance(self.epoch, str):
            if self.epoch in ("(none)", "", "0"):
                self.epoch = 0
            else:
                self.epoch = int(self.epoch)

    @property
    def nevra(self) -> str:
        """Return full NEVRA string."""
        return f"{self.name}-{self.epoch}:{self.version}-{self.release}.{self.arch}"

    @property
    def nvra(self) -> str:
        """Return NVRA string (no epoch)."""
        return f"{self.name}-{self.version}-{self.release}.{self.arch}"

    @property
    def evr(self) -> str:
        """Return EVR string."""
        return f"{self.epoch}:{self.version}-{self.release}"

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, RPMVersion):
            return NotImplemented
        return (
            self.name == other.name
            and self.arch == other.arch
            and self.epoch == other.epoch
            and self.version == other.version
            and self.release == other.release
        )

    def __lt__(self, other: object) -> bool:
        if not isinstance(other, RPMVersion):
            return NotImplemented

        # Only compare same name and arch
        if self.name != other.name or self.arch != other.arch:
            return NotImplemented

        # Compare epoch first
        if self.epoch != other.epoch:
            return self.epoch < other.epoch

        # Compare version
        version_cmp = _compare_version_strings(self.version, other.version)
        if version_cmp != 0:
            return version_cmp < 0

        # Compare release
        release_cmp = _compare_version_strings(self.release, other.release)
        return release_cmp < 0

    def __hash__(self) -> int:
        return hash((self.name, self.epoch, self.version, self.release, self.arch))


def _split_version_string(version: str) -> list[str]:
    """
    Split a version string into comparable segments.

    Segments are either numeric or alphabetic. Separators are ignored.

    Examples:
        "1.2.3" -> ["1", "2", "3"]
        "1.2a3" -> ["1", "2", "a", "3"]
        "1.2.3-4.el9" -> ["1", "2", "3", "4", "el", "9"]
    """
    segments = []
    current = ""
    current_is_digit = None

    for char in version:
        if char.isdigit():
            if current_is_digit is False and current:
                segments.append(current)
                current = ""
            current += char
            current_is_digit = True
        elif char.isalpha():
            if current_is_digit is True and current:
                segments.append(current)
                current = ""
            current += char
            current_is_digit = False
        else:
            # Separator character
            if current:
                segments.append(current)
                current = ""
            current_is_digit = None

    if current:
        segments.append(current)

    return segments


def _compare_version_strings(v1: str, v2: str) -> int:
    """
    Compare two version strings using RPM's comparison algorithm.

    Returns:
        -1 if v1 < v2
         0 if v1 == v2
         1 if v1 > v2
    """
    segments1 = _split_version_string(v1)
    segments2 = _split_version_string(v2)

    for s1, s2 in zip(segments1, segments2):
        # Both numeric
        if s1.isdigit() and s2.isdigit():
            n1, n2 = int(s1), int(s2)
            if n1 < n2:
                return -1
            if n1 > n2:
                return 1
        # Both alphabetic
        elif s1.isalpha() and s2.isalpha():
            if s1 < s2:
                return -1
            if s1 > s2:
                return 1
        # Mixed: numeric > alphabetic
        elif s1.isdigit():
            return 1
        else:
            return -1

    # All compared segments are equal, longer version is greater
    if len(segments1) < len(segments2):
        return -1
    if len(segments1) > len(segments2):
        return 1

    return 0


def compare_versions(
    installed: dict, available: dict
) -> int:
    """
    Compare installed package version against available package version.

    Args:
        installed: Dict with epoch, version, release keys
        available: Dict with epoch, version, release keys

    Returns:
        -1 if installed < available (update available)
         0 if installed == available
         1 if installed > available (downgrade)
    """
    # Parse epochs
    i_epoch = installed.get("epoch", 0)
    a_epoch = available.get("epoch", 0)

    if isinstance(i_epoch, str):
        i_epoch = 0 if i_epoch in ("(none)", "", "0") else int(i_epoch)
    if isinstance(a_epoch, str):
        a_epoch = 0 if a_epoch in ("(none)", "", "0") else int(a_epoch)

    # Compare epochs
    if i_epoch < a_epoch:
        return -1
    if i_epoch > a_epoch:
        return 1

    # Compare versions
    i_version = installed.get("version", "0")
    a_version = available.get("version", "0")
    version_cmp = _compare_version_strings(i_version, a_version)
    if version_cmp != 0:
        return version_cmp

    # Compare releases
    i_release = installed.get("release", "0")
    a_release = available.get("release", "0")
    return _compare_version_strings(i_release, a_release)


def parse_nevra(nevra_string: str) -> Optional[RPMVersion]:
    """
    Parse a NEVRA string into an RPMVersion object.

    Supported formats:
        name-epoch:version-release.arch
        name-version-release.arch (epoch defaults to 0)

    Args:
        nevra_string: Package identifier in NEVRA format

    Returns:
        RPMVersion object or None if parsing fails
    """
    # Pattern for NEVRA with epoch
    pattern_with_epoch = re.compile(
        r"^(.+)-(\d+):([^-]+)-([^.]+)\.(.+)$"
    )

    # Pattern for NEVRA without epoch (name-version-release.arch)
    pattern_without_epoch = re.compile(
        r"^(.+)-([^-]+)-([^.]+)\.(.+)$"
    )

    # Try with epoch first
    match = pattern_with_epoch.match(nevra_string)
    if match:
        name, epoch, version, release, arch = match.groups()
        return RPMVersion(
            name=name,
            epoch=int(epoch),
            version=version,
            release=release,
            arch=arch,
        )

    # Try without epoch
    match = pattern_without_epoch.match(nevra_string)
    if match:
        name, version, release, arch = match.groups()
        return RPMVersion(
            name=name,
            epoch=0,
            version=version,
            release=release,
            arch=arch,
        )

    return None


def parse_rpm_qa_line(line: str) -> Optional[dict]:
    """
    Parse a line from rpm -qa output with custom format.

    Expected format: name|epoch|version|release|arch|installtime

    Args:
        line: Single line from rpm -qa output

    Returns:
        Dict with package info or None if parsing fails
    """
    parts = line.strip().split("|")

    if len(parts) < 5:
        return None

    name, epoch, version, release, arch = parts[:5]
    installtime = parts[5] if len(parts) > 5 else None

    # Normalize epoch
    if epoch in ("(none)", "", "None"):
        epoch = "0"

    return {
        "name": name,
        "epoch": epoch,
        "version": version,
        "release": release,
        "arch": arch,
        "installtime": installtime,
    }


def is_update_available(installed: dict, available: dict) -> bool:
    """
    Check if an update is available for a package.

    Args:
        installed: Dict with package info (epoch, version, release)
        available: Dict with available package info

    Returns:
        True if available version is newer than installed
    """
    return compare_versions(installed, available) < 0


def format_evr(epoch: int | str, version: str, release: str) -> str:
    """
    Format epoch-version-release string.

    Args:
        epoch: Package epoch
        version: Package version
        release: Package release

    Returns:
        Formatted EVR string
    """
    if isinstance(epoch, str):
        epoch = 0 if epoch in ("(none)", "", "0") else int(epoch)

    if epoch > 0:
        return f"{epoch}:{version}-{release}"
    return f"{version}-{release}"
