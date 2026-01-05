"""Tests for disk_space module."""

import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock
from collections import namedtuple

from disk_space import (
    get_disk_space_free,
    get_disk_space_info,
    format_bytes,
    has_sufficient_space,
)


# Mock disk usage namedtuple
DiskUsage = namedtuple("DiskUsage", ["total", "used", "free"])


class TestGetDiskSpaceFree:
    """Tests for get_disk_space_free function."""

    @patch("disk_space.shutil.disk_usage")
    def test_returns_free_space_in_bytes(self, mock_disk_usage):
        """Test that function returns free space in bytes."""
        mock_disk_usage.return_value = DiskUsage(
            total=1000000000, used=600000000, free=400000000
        )

        result = get_disk_space_free("/")

        assert result == 400000000
        mock_disk_usage.assert_called_once()

    @patch("disk_space.Path.exists")
    @patch("disk_space.shutil.disk_usage")
    def test_accepts_string_path(self, mock_disk_usage, mock_exists):
        """Test that function accepts string path."""
        mock_exists.return_value = True
        mock_disk_usage.return_value = DiskUsage(
            total=1000000000, used=600000000, free=400000000
        )

        result = get_disk_space_free("/home/user")

        assert isinstance(result, int)
        mock_disk_usage.assert_called_once()

    @patch("disk_space.Path.exists")
    @patch("disk_space.shutil.disk_usage")
    def test_accepts_path_object(self, mock_disk_usage, mock_exists):
        """Test that function accepts Path object."""
        mock_exists.return_value = True
        mock_disk_usage.return_value = DiskUsage(
            total=1000000000, used=600000000, free=400000000
        )

        result = get_disk_space_free(Path("/home/user"))

        assert isinstance(result, int)
        mock_disk_usage.assert_called_once()

    @patch("disk_space.Path.exists")
    def test_raises_error_for_nonexistent_path(self, mock_exists):
        """Test that FileNotFoundError is raised for nonexistent path."""
        mock_exists.return_value = False

        with pytest.raises(FileNotFoundError, match="Path does not exist"):
            get_disk_space_free("/nonexistent/path")

    @patch("disk_space.shutil.disk_usage")
    def test_default_path_is_root(self, mock_disk_usage):
        """Test that default path is root directory."""
        mock_disk_usage.return_value = DiskUsage(
            total=1000000000, used=600000000, free=400000000
        )

        get_disk_space_free()

        # Check that the path passed to disk_usage is root
        call_args = mock_disk_usage.call_args[0][0]
        assert str(call_args) == "/"


class TestGetDiskSpaceInfo:
    """Tests for get_disk_space_info function."""

    @patch("disk_space.shutil.disk_usage")
    def test_returns_complete_disk_info(self, mock_disk_usage):
        """Test that function returns total, used, and free space."""
        mock_disk_usage.return_value = DiskUsage(
            total=1000000000, used=600000000, free=400000000
        )

        result = get_disk_space_info("/")

        assert result == {
            "total": 1000000000,
            "used": 600000000,
            "free": 400000000,
        }

    @patch("disk_space.shutil.disk_usage")
    def test_returns_dict_with_correct_keys(self, mock_disk_usage):
        """Test that result dictionary has correct keys."""
        mock_disk_usage.return_value = DiskUsage(
            total=1000000000, used=600000000, free=400000000
        )

        result = get_disk_space_info("/")

        assert set(result.keys()) == {"total", "used", "free"}

    @patch("disk_space.Path.exists")
    def test_raises_error_for_nonexistent_path(self, mock_exists):
        """Test that FileNotFoundError is raised for nonexistent path."""
        mock_exists.return_value = False

        with pytest.raises(FileNotFoundError, match="Path does not exist"):
            get_disk_space_info("/nonexistent/path")


class TestFormatBytes:
    """Tests for format_bytes function."""

    def test_formats_bytes(self):
        """Test formatting bytes."""
        assert format_bytes(500) == "500.00 B"

    def test_formats_kilobytes(self):
        """Test formatting kilobytes."""
        assert format_bytes(1024) == "1.00 KB"
        assert format_bytes(2048) == "2.00 KB"

    def test_formats_megabytes(self):
        """Test formatting megabytes."""
        assert format_bytes(1024 * 1024) == "1.00 MB"
        assert format_bytes(1536 * 1024) == "1.50 MB"

    def test_formats_gigabytes(self):
        """Test formatting gigabytes."""
        assert format_bytes(1024 * 1024 * 1024) == "1.00 GB"
        assert format_bytes(2.5 * 1024 * 1024 * 1024) == "2.50 GB"

    def test_formats_terabytes(self):
        """Test formatting terabytes."""
        assert format_bytes(1024 * 1024 * 1024 * 1024) == "1.00 TB"

    def test_formats_petabytes(self):
        """Test formatting petabytes."""
        assert format_bytes(1024 * 1024 * 1024 * 1024 * 1024) == "1.00 PB"

    def test_custom_decimal_places(self):
        """Test custom decimal places."""
        assert format_bytes(1536 * 1024, decimal_places=1) == "1.5 MB"
        assert format_bytes(1536 * 1024, decimal_places=3) == "1.500 MB"

    def test_zero_bytes(self):
        """Test formatting zero bytes."""
        assert format_bytes(0) == "0.00 B"


class TestHasSufficientSpace:
    """Tests for has_sufficient_space function."""

    @patch("disk_space.get_disk_space_free")
    def test_returns_true_when_sufficient_space(self, mock_get_free):
        """Test returns True when there is sufficient space."""
        mock_get_free.return_value = 1000000000  # 1 GB

        result = has_sufficient_space("/", required_bytes=500000000)  # 500 MB

        assert result is True

    @patch("disk_space.get_disk_space_free")
    def test_returns_false_when_insufficient_space(self, mock_get_free):
        """Test returns False when there is insufficient space."""
        mock_get_free.return_value = 100000000  # 100 MB

        result = has_sufficient_space("/", required_bytes=500000000)  # 500 MB

        assert result is False

    @patch("disk_space.get_disk_space_free")
    def test_returns_true_when_exact_space(self, mock_get_free):
        """Test returns True when free space exactly matches required."""
        mock_get_free.return_value = 500000000

        result = has_sufficient_space("/", required_bytes=500000000)

        assert result is True

    @patch("disk_space.get_disk_space_free")
    def test_accepts_path_object(self, mock_get_free):
        """Test that function accepts Path object."""
        mock_get_free.return_value = 1000000000

        result = has_sufficient_space(Path("/home/user"), required_bytes=500000000)

        assert result is True
        mock_get_free.assert_called_once_with(Path("/home/user"))


class TestIntegration:
    """Integration tests that use real filesystem."""

    def test_get_disk_space_free_returns_positive_int(self):
        """Test that real call returns positive integer."""
        result = get_disk_space_free("/")

        assert isinstance(result, int)
        assert result > 0

    def test_get_disk_space_info_returns_valid_data(self):
        """Test that real call returns valid disk info."""
        result = get_disk_space_info("/")

        assert isinstance(result, dict)
        assert result["total"] > 0
        assert result["used"] >= 0
        assert result["free"] > 0
        # Verify that total = used + free (approximately, accounting for reserved space)
        assert result["total"] >= result["used"] + result["free"]

    def test_format_bytes_real_disk_space(self):
        """Test formatting real disk space values."""
        free_space = get_disk_space_free("/")
        formatted = format_bytes(free_space)

        assert isinstance(formatted, str)
        assert any(unit in formatted for unit in ["B", "KB", "MB", "GB", "TB", "PB"])

    def test_has_sufficient_space_with_small_requirement(self):
        """Test has_sufficient_space with small requirement."""
        # Require just 1 byte - should always pass
        result = has_sufficient_space("/", required_bytes=1)

        assert result is True


class TestEdgeCases:
    """Test edge cases and error handling."""

    @patch("disk_space.shutil.disk_usage")
    def test_handles_zero_free_space(self, mock_disk_usage):
        """Test handling of zero free space."""
        mock_disk_usage.return_value = DiskUsage(
            total=1000000000, used=1000000000, free=0
        )

        result = get_disk_space_free("/")

        assert result == 0

    def test_format_bytes_with_negative_value(self):
        """Test that format_bytes handles negative values gracefully."""
        # This is an edge case - in practice bytes shouldn't be negative
        result = format_bytes(-1024)
        assert isinstance(result, str)

    @patch("disk_space.get_disk_space_free")
    def test_has_sufficient_space_with_zero_requirement(self, mock_get_free):
        """Test has_sufficient_space with zero bytes required."""
        mock_get_free.return_value = 1000000000

        result = has_sufficient_space("/", required_bytes=0)

        assert result is True
