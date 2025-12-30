"""
Pytest configuration and fixtures for update calculator tests.
"""

import json
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest


@pytest.fixture
def temp_dir():
    """Provide a temporary directory for tests."""
    with TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)


@pytest.fixture
def sample_manifest():
    """Provide a sample host manifest."""
    return {
        "manifest_version": "1.0",
        "host_id": "test-host-001",
        "hostname": "test-server",
        "timestamp": "2024-01-15T10:00:00Z",
        "os_release": {
            "id": "rhel",
            "version": "9.6",
        },
        "kernel": "5.14.0-427.13.1.el9_4.x86_64",
        "arch": "x86_64",
        "packages": [
            {
                "name": "bash",
                "epoch": "0",
                "version": "5.1.8",
                "release": "6.el9",
                "arch": "x86_64",
                "installtime": 1705313000,
            },
            {
                "name": "kernel",
                "epoch": "0",
                "version": "5.14.0",
                "release": "427.13.1.el9_4",
                "arch": "x86_64",
                "installtime": 1705313000,
            },
            {
                "name": "openssl",
                "epoch": "1",
                "version": "3.0.7",
                "release": "24.el9",
                "arch": "x86_64",
                "installtime": 1705313000,
            },
        ],
        "enabled_repos": [
            "rhel-9-for-x86_64-baseos-rpms",
            "rhel-9-for-x86_64-appstream-rpms",
        ],
    }


@pytest.fixture
def sample_repo_packages():
    """Provide sample repository package data."""
    return {
        "bash.x86_64": {
            "name": "bash",
            "epoch": "0",
            "version": "5.1.8",
            "release": "9.el9",  # Newer than manifest
            "arch": "x86_64",
        },
        "kernel.x86_64": {
            "name": "kernel",
            "epoch": "0",
            "version": "5.14.0",
            "release": "427.13.1.el9_4",  # Same as manifest
            "arch": "x86_64",
        },
        "openssl.x86_64": {
            "name": "openssl",
            "epoch": "1",
            "version": "3.0.7",
            "release": "27.el9",  # Newer than manifest
            "arch": "x86_64",
        },
        "httpd.x86_64": {
            "name": "httpd",
            "epoch": "0",
            "version": "2.4.57",
            "release": "5.el9",
            "arch": "x86_64",
        },
    }


@pytest.fixture
def mock_mirror_dir(temp_dir, sample_repo_packages):
    """Create a mock mirror directory with package cache."""
    mirror_dir = temp_dir / "mirror"
    repo_dir = mirror_dir / "rhel9" / "x86_64" / "baseos"
    repo_dir.mkdir(parents=True)

    # Write package cache
    cache_file = repo_dir / ".package_cache.json"
    with open(cache_file, "w") as f:
        json.dump(sample_repo_packages, f)

    return mirror_dir


@pytest.fixture
def mock_manifests_dir(temp_dir, sample_manifest):
    """Create a mock manifests directory with sample manifest."""
    manifests_dir = temp_dir / "manifests"
    host_dir = manifests_dir / "processed" / sample_manifest["host_id"] / "latest"
    host_dir.mkdir(parents=True)

    # Write manifest
    manifest_file = host_dir / "manifest.json"
    with open(manifest_file, "w") as f:
        json.dump(sample_manifest, f)

    # Write index
    index_dir = manifests_dir / "index"
    index_dir.mkdir(parents=True)
    index_file = index_dir / "manifest_index.json"
    with open(index_file, "w") as f:
        json.dump({
            "hosts": {
                sample_manifest["host_id"]: {
                    "first_seen": "2024-01-15T10:00:00Z",
                    "last_updated": "2024-01-15T10:00:00Z",
                    "os_id": "rhel",
                    "os_version": "9.6",
                }
            },
            "last_updated": "2024-01-15T10:00:00Z",
        }, f)

    return manifests_dir


@pytest.fixture
def rpm_version_pairs():
    """Provide pairs of RPM versions for comparison testing."""
    return [
        # (installed, available, expected_result)
        # -1 = update available, 0 = same, 1 = installed is newer
        (
            {"epoch": "0", "version": "1.0", "release": "1.el9"},
            {"epoch": "0", "version": "1.0", "release": "2.el9"},
            -1,  # update available
        ),
        (
            {"epoch": "0", "version": "1.0", "release": "1.el9"},
            {"epoch": "0", "version": "1.0", "release": "1.el9"},
            0,  # same version
        ),
        (
            {"epoch": "0", "version": "1.0", "release": "2.el9"},
            {"epoch": "0", "version": "1.0", "release": "1.el9"},
            1,  # installed is newer
        ),
        (
            {"epoch": "0", "version": "1.0", "release": "1.el9"},
            {"epoch": "1", "version": "1.0", "release": "1.el9"},
            -1,  # epoch bump = update
        ),
        (
            {"epoch": "0", "version": "1.0", "release": "1.el9"},
            {"epoch": "0", "version": "2.0", "release": "1.el9"},
            -1,  # version bump = update
        ),
        (
            {"epoch": "(none)", "version": "1.0", "release": "1"},
            {"epoch": "0", "version": "1.0", "release": "2"},
            -1,  # epoch "(none)" treated as 0
        ),
    ]
