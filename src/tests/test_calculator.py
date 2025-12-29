"""
Tests for the UpdateCalculator class.
"""

import pytest
from update_calculator.calculator import UpdateCalculator, PackageUpdate, UpdateResult


class TestPackageUpdate:
    """Tests for PackageUpdate dataclass."""

    def test_create_package_update(self):
        """Test creating a PackageUpdate object."""
        update = PackageUpdate(
            name="bash",
            arch="x86_64",
            channel="baseos",
            installed_epoch="0",
            installed_version="5.1.8",
            installed_release="6.el9",
            available_epoch="0",
            available_version="5.1.8",
            available_release="9.el9",
        )
        assert update.name == "bash"
        assert update.arch == "x86_64"

    def test_installed_evr(self):
        """Test installed_evr property."""
        update = PackageUpdate(
            name="bash",
            arch="x86_64",
            channel="baseos",
            installed_epoch="0",
            installed_version="5.1.8",
            installed_release="6.el9",
            available_epoch="0",
            available_version="5.1.8",
            available_release="9.el9",
        )
        assert update.installed_evr == "5.1.8-6.el9"

    def test_available_evr(self):
        """Test available_evr property."""
        update = PackageUpdate(
            name="openssl",
            arch="x86_64",
            channel="baseos",
            installed_epoch="1",
            installed_version="3.0.7",
            installed_release="24.el9",
            available_epoch="1",
            available_version="3.0.7",
            available_release="27.el9",
        )
        assert update.available_evr == "1:3.0.7-27.el9"

    def test_to_dict(self):
        """Test converting PackageUpdate to dict."""
        update = PackageUpdate(
            name="bash",
            arch="x86_64",
            channel="baseos",
            installed_epoch="0",
            installed_version="5.1.8",
            installed_release="6.el9",
            available_epoch="0",
            available_version="5.1.8",
            available_release="9.el9",
        )
        result = update.to_dict()
        assert result["name"] == "bash"
        assert result["installed"]["version"] == "5.1.8"
        assert result["available"]["release"] == "9.el9"


class TestUpdateResult:
    """Tests for UpdateResult dataclass."""

    def test_create_update_result(self):
        """Test creating an UpdateResult object."""
        result = UpdateResult(
            host_id="test-host",
            profile="rhel9",
            os_id="rhel",
            os_version="9.6",
            computed_at="2024-01-15T10:00:00Z",
        )
        assert result.host_id == "test-host"
        assert result.update_count == 0

    def test_update_count(self):
        """Test update_count property."""
        result = UpdateResult(
            host_id="test-host",
            profile="rhel9",
            os_id="rhel",
            os_version="9.6",
            computed_at="2024-01-15T10:00:00Z",
            updates=[
                PackageUpdate(
                    "bash", "x86_64", "baseos",
                    "0", "5.1.8", "6.el9",
                    "0", "5.1.8", "9.el9"
                ),
                PackageUpdate(
                    "openssl", "x86_64", "baseos",
                    "1", "3.0.7", "24.el9",
                    "1", "3.0.7", "27.el9"
                ),
            ],
        )
        assert result.update_count == 2

    def test_to_dict(self):
        """Test converting UpdateResult to dict."""
        result = UpdateResult(
            host_id="test-host",
            profile="rhel9",
            os_id="rhel",
            os_version="9.6",
            computed_at="2024-01-15T10:00:00Z",
        )
        data = result.to_dict()
        assert data["host_id"] == "test-host"
        assert data["profile"] == "rhel9"
        assert data["update_count"] == 0
        assert data["updates"] == []

    def test_to_json(self):
        """Test converting UpdateResult to JSON."""
        result = UpdateResult(
            host_id="test-host",
            profile="rhel9",
            os_id="rhel",
            os_version="9.6",
            computed_at="2024-01-15T10:00:00Z",
        )
        json_str = result.to_json()
        assert '"host_id": "test-host"' in json_str
        assert '"profile": "rhel9"' in json_str


class TestUpdateCalculator:
    """Tests for UpdateCalculator class."""

    def test_init(self, temp_dir):
        """Test initializing UpdateCalculator."""
        calc = UpdateCalculator(
            mirror_dir=temp_dir / "mirror",
            manifests_dir=temp_dir / "manifests",
        )
        assert calc.mirror_dir.name == "mirror"
        assert calc.manifests_dir.name == "manifests"

    def test_get_profile_for_os_rhel9(self):
        """Test profile detection for RHEL 9."""
        calc = UpdateCalculator("/mirror", "/manifests")
        assert calc.get_profile_for_os("rhel", "9.6") == "rhel9"
        assert calc.get_profile_for_os("rhel", "9.4") == "rhel9"

    def test_get_profile_for_os_rhel8(self):
        """Test profile detection for RHEL 8."""
        calc = UpdateCalculator("/mirror", "/manifests")
        assert calc.get_profile_for_os("rhel", "8.10") == "rhel8"
        assert calc.get_profile_for_os("rhel", "8.8") == "rhel8"

    def test_get_profile_for_os_centos(self):
        """Test profile detection for CentOS."""
        calc = UpdateCalculator("/mirror", "/manifests")
        assert calc.get_profile_for_os("centos", "9") == "rhel9"
        assert calc.get_profile_for_os("rocky", "9.3") == "rhel9"

    def test_load_manifest(self, mock_manifests_dir, sample_manifest):
        """Test loading a host manifest."""
        calc = UpdateCalculator(
            mirror_dir="/mirror",
            manifests_dir=mock_manifests_dir,
        )
        manifest = calc.load_manifest(sample_manifest["host_id"])
        assert manifest is not None
        assert manifest["host_id"] == sample_manifest["host_id"]
        assert len(manifest["packages"]) == 3

    def test_load_manifest_not_found(self, mock_manifests_dir):
        """Test loading a non-existent manifest."""
        calc = UpdateCalculator(
            mirror_dir="/mirror",
            manifests_dir=mock_manifests_dir,
        )
        manifest = calc.load_manifest("nonexistent-host")
        assert manifest is None

    def test_load_repo_packages(self, mock_mirror_dir, sample_repo_packages):
        """Test loading repository packages."""
        calc = UpdateCalculator(
            mirror_dir=mock_mirror_dir,
            manifests_dir="/manifests",
        )
        packages = calc.load_repo_packages("rhel9", "x86_64", "baseos")
        assert len(packages) == len(sample_repo_packages)
        assert "bash.x86_64" in packages

    def test_load_repo_packages_caching(self, mock_mirror_dir):
        """Test that repository packages are cached."""
        calc = UpdateCalculator(
            mirror_dir=mock_mirror_dir,
            manifests_dir="/manifests",
        )
        # First load
        packages1 = calc.load_repo_packages("rhel9", "x86_64", "baseos")
        # Second load (should use cache)
        packages2 = calc.load_repo_packages("rhel9", "x86_64", "baseos")
        assert packages1 is packages2

    def test_compute_updates_for_host(
        self, mock_mirror_dir, mock_manifests_dir, sample_manifest
    ):
        """Test computing updates for a host."""
        calc = UpdateCalculator(
            mirror_dir=mock_mirror_dir,
            manifests_dir=mock_manifests_dir,
        )
        result = calc.compute_updates_for_host(sample_manifest["host_id"])

        assert result.host_id == sample_manifest["host_id"]
        assert result.profile == "rhel9"
        assert result.os_id == "rhel"
        assert result.os_version == "9.6"

        # Should find 2 updates: bash and openssl
        # (kernel is same version, so no update)
        assert result.update_count == 2

        update_names = [u.name for u in result.updates]
        assert "bash" in update_names
        assert "openssl" in update_names
        assert "kernel" not in update_names

    def test_compute_updates_for_nonexistent_host(
        self, mock_mirror_dir, mock_manifests_dir
    ):
        """Test computing updates for non-existent host."""
        calc = UpdateCalculator(
            mirror_dir=mock_mirror_dir,
            manifests_dir=mock_manifests_dir,
        )
        result = calc.compute_updates_for_host("nonexistent-host")

        assert result.host_id == "nonexistent-host"
        assert result.update_count == 0
        assert len(result.errors) > 0

    def test_generate_summary(self, mock_mirror_dir, mock_manifests_dir, sample_manifest):
        """Test generating update summary."""
        calc = UpdateCalculator(
            mirror_dir=mock_mirror_dir,
            manifests_dir=mock_manifests_dir,
        )
        result = calc.compute_updates_for_host(sample_manifest["host_id"])
        summary = calc.generate_summary([result])

        assert summary["total_hosts"] == 1
        assert summary["hosts_with_updates"] == 1
        assert summary["total_updates"] == 2
        assert len(summary["hosts"]) == 1
        assert summary["hosts"][0]["host_id"] == sample_manifest["host_id"]


class TestIntegration:
    """Integration tests for the update calculator."""

    def test_full_workflow(
        self, mock_mirror_dir, mock_manifests_dir, sample_manifest
    ):
        """Test complete update calculation workflow."""
        # Initialize calculator
        calc = UpdateCalculator(
            mirror_dir=mock_mirror_dir,
            manifests_dir=mock_manifests_dir,
        )

        # Compute updates
        result = calc.compute_updates_for_host(sample_manifest["host_id"])

        # Verify result structure
        assert result.host_id == sample_manifest["host_id"]
        assert result.computed_at is not None
        assert len(result.errors) == 0

        # Verify updates
        for update in result.updates:
            assert update.name in ["bash", "openssl"]
            assert update.channel == "baseos"
            assert update.arch == "x86_64"

        # Convert to JSON (tests serialization)
        json_str = result.to_json()
        assert '"host_id"' in json_str
        assert '"updates"' in json_str

        # Generate summary
        summary = calc.generate_summary([result])
        assert summary["total_updates"] == result.update_count
