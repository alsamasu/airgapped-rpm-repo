"""
Tests for RPM utilities module.
"""

from update_calculator.rpm_utils import (
    RPMVersion,
    compare_versions,
    format_evr,
    is_update_available,
    parse_nevra,
    parse_rpm_qa_line,
)


class TestRPMVersion:
    """Tests for RPMVersion class."""

    def test_create_rpm_version(self):
        """Test creating an RPMVersion object."""
        version = RPMVersion(
            name="bash",
            epoch=0,
            version="5.1.8",
            release="6.el9",
            arch="x86_64",
        )
        assert version.name == "bash"
        assert version.epoch == 0
        assert version.version == "5.1.8"
        assert version.release == "6.el9"
        assert version.arch == "x86_64"

    def test_epoch_normalization(self):
        """Test that epoch is normalized to integer."""
        version = RPMVersion(
            name="test",
            epoch="(none)",
            version="1.0",
            release="1",
            arch="x86_64",
        )
        assert version.epoch == 0

        version2 = RPMVersion(
            name="test",
            epoch="2",
            version="1.0",
            release="1",
            arch="x86_64",
        )
        assert version2.epoch == 2

    def test_nevra_property(self):
        """Test NEVRA string generation."""
        version = RPMVersion(
            name="bash",
            epoch=0,
            version="5.1.8",
            release="6.el9",
            arch="x86_64",
        )
        assert version.nevra == "bash-0:5.1.8-6.el9.x86_64"

    def test_nvra_property(self):
        """Test NVRA string generation."""
        version = RPMVersion(
            name="bash",
            epoch=0,
            version="5.1.8",
            release="6.el9",
            arch="x86_64",
        )
        assert version.nvra == "bash-5.1.8-6.el9.x86_64"

    def test_evr_property(self):
        """Test EVR string generation."""
        version = RPMVersion(
            name="bash",
            epoch=1,
            version="5.1.8",
            release="6.el9",
            arch="x86_64",
        )
        assert version.evr == "1:5.1.8-6.el9"

    def test_version_comparison_same(self):
        """Test comparing identical versions."""
        v1 = RPMVersion("bash", 0, "5.1.8", "6.el9", "x86_64")
        v2 = RPMVersion("bash", 0, "5.1.8", "6.el9", "x86_64")
        assert v1 == v2
        assert not v1 < v2
        assert not v1 > v2

    def test_version_comparison_release(self):
        """Test comparing versions with different releases."""
        v1 = RPMVersion("bash", 0, "5.1.8", "6.el9", "x86_64")
        v2 = RPMVersion("bash", 0, "5.1.8", "7.el9", "x86_64")
        assert v1 < v2
        assert v2 > v1

    def test_version_comparison_version(self):
        """Test comparing versions with different versions."""
        v1 = RPMVersion("bash", 0, "5.1.8", "6.el9", "x86_64")
        v2 = RPMVersion("bash", 0, "5.2.0", "1.el9", "x86_64")
        assert v1 < v2

    def test_version_comparison_epoch(self):
        """Test comparing versions with different epochs."""
        v1 = RPMVersion("openssl", 1, "3.0.7", "24.el9", "x86_64")
        v2 = RPMVersion("openssl", 2, "3.0.7", "24.el9", "x86_64")
        assert v1 < v2


class TestCompareVersions:
    """Tests for compare_versions function."""

    def test_compare_versions_same(self):
        """Test comparing identical versions."""
        installed = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        assert compare_versions(installed, available) == 0

    def test_compare_versions_release_newer(self):
        """Test when release is newer."""
        installed = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "1.0", "release": "2.el9"}
        assert compare_versions(installed, available) == -1

    def test_compare_versions_version_newer(self):
        """Test when version is newer."""
        installed = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "2.0", "release": "1.el9"}
        assert compare_versions(installed, available) == -1

    def test_compare_versions_epoch_newer(self):
        """Test when epoch is newer."""
        installed = {"epoch": "0", "version": "2.0", "release": "1.el9"}
        available = {"epoch": "1", "version": "1.0", "release": "1.el9"}
        assert compare_versions(installed, available) == -1

    def test_compare_versions_installed_newer(self):
        """Test when installed is newer."""
        installed = {"epoch": "0", "version": "2.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        assert compare_versions(installed, available) == 1

    def test_compare_versions_epoch_none(self):
        """Test epoch '(none)' is treated as 0."""
        installed = {"epoch": "(none)", "version": "1.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "1.0", "release": "2.el9"}
        assert compare_versions(installed, available) == -1

    def test_compare_versions_fixture(self, rpm_version_pairs):
        """Test version comparison with fixture data."""
        for installed, available, expected in rpm_version_pairs:
            result = compare_versions(installed, available)
            assert result == expected, f"{installed} vs {available}"


class TestParseNevra:
    """Tests for parse_nevra function."""

    def test_parse_nevra_with_epoch(self):
        """Test parsing NEVRA with epoch."""
        result = parse_nevra("openssl-1:3.0.7-24.el9.x86_64")
        assert result is not None
        assert result.name == "openssl"
        assert result.epoch == 1
        assert result.version == "3.0.7"
        assert result.release == "24.el9"
        assert result.arch == "x86_64"

    def test_parse_nevra_without_epoch(self):
        """Test parsing NEVRA without epoch."""
        result = parse_nevra("bash-5.1.8-6.el9.x86_64")
        assert result is not None
        assert result.name == "bash"
        assert result.epoch == 0
        assert result.version == "5.1.8"
        assert result.release == "6.el9"
        assert result.arch == "x86_64"

    def test_parse_nevra_complex_name(self):
        """Test parsing NEVRA with complex package name."""
        result = parse_nevra("python3-rpm-4.16.1.3-27.el9.x86_64")
        assert result is not None
        assert result.name == "python3-rpm"
        assert result.version == "4.16.1.3"

    def test_parse_nevra_noarch(self):
        """Test parsing NEVRA with noarch."""
        result = parse_nevra("python3-setuptools-53.0.0-12.el9.noarch")
        assert result is not None
        assert result.arch == "noarch"

    def test_parse_nevra_invalid(self):
        """Test parsing invalid NEVRA returns None."""
        result = parse_nevra("invalid-string")
        assert result is None


class TestParseRpmQaLine:
    """Tests for parse_rpm_qa_line function."""

    def test_parse_standard_line(self):
        """Test parsing standard rpm -qa output line."""
        line = "bash|0|5.1.8|6.el9|x86_64|1705313000"
        result = parse_rpm_qa_line(line)
        assert result is not None
        assert result["name"] == "bash"
        assert result["epoch"] == "0"
        assert result["version"] == "5.1.8"
        assert result["release"] == "6.el9"
        assert result["arch"] == "x86_64"
        assert result["installtime"] == "1705313000"

    def test_parse_epoch_none(self):
        """Test parsing with epoch '(none)'."""
        line = "bash|(none)|5.1.8|6.el9|x86_64|1705313000"
        result = parse_rpm_qa_line(line)
        assert result is not None
        assert result["epoch"] == "0"

    def test_parse_invalid_line(self):
        """Test parsing invalid line returns None."""
        line = "invalid"
        result = parse_rpm_qa_line(line)
        assert result is None


class TestIsUpdateAvailable:
    """Tests for is_update_available function."""

    def test_update_available(self):
        """Test when update is available."""
        installed = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "1.0", "release": "2.el9"}
        assert is_update_available(installed, available) is True

    def test_no_update_available(self):
        """Test when no update is available."""
        installed = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        assert is_update_available(installed, available) is False

    def test_installed_newer(self):
        """Test when installed is newer than available."""
        installed = {"epoch": "0", "version": "2.0", "release": "1.el9"}
        available = {"epoch": "0", "version": "1.0", "release": "1.el9"}
        assert is_update_available(installed, available) is False


class TestFormatEvr:
    """Tests for format_evr function."""

    def test_format_evr_with_epoch(self):
        """Test formatting EVR with non-zero epoch."""
        result = format_evr(1, "3.0.7", "24.el9")
        assert result == "1:3.0.7-24.el9"

    def test_format_evr_without_epoch(self):
        """Test formatting EVR with zero epoch."""
        result = format_evr(0, "5.1.8", "6.el9")
        assert result == "5.1.8-6.el9"

    def test_format_evr_string_epoch(self):
        """Test formatting EVR with string epoch."""
        result = format_evr("(none)", "1.0", "1")
        assert result == "1.0-1"
