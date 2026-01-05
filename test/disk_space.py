"""Module for checking disk space."""

import shutil
from pathlib import Path
from typing import Dict, Union


def get_disk_space_free(path: Union[str, Path] = "/") -> int:
    """
    Get free disk space in bytes for the filesystem containing the given path.

    Args:
        path: The path to check. Defaults to root directory.

    Returns:
        Free disk space in bytes.

    Raises:
        FileNotFoundError: If the path does not exist.
        PermissionError: If lacking permission to access the path.
    """
    path = Path(path)

    if not path.exists():
        raise FileNotFoundError(f"Path does not exist: {path}")

    usage = shutil.disk_usage(path)
    return usage.free


def get_disk_space_info(path: Union[str, Path] = "/") -> Dict[str, int]:
    """
    Get comprehensive disk space information for the given path.

    Args:
        path: The path to check. Defaults to root directory.

    Returns:
        Dictionary with 'total', 'used', and 'free' space in bytes.

    Raises:
        FileNotFoundError: If the path does not exist.
        PermissionError: If lacking permission to access the path.
    """
    path = Path(path)

    if not path.exists():
        raise FileNotFoundError(f"Path does not exist: {path}")

    usage = shutil.disk_usage(path)
    return {
        "total": usage.total,
        "used": usage.used,
        "free": usage.free,
    }


def format_bytes(bytes_value: int, decimal_places: int = 2) -> str:
    """
    Format bytes into human-readable format (KB, MB, GB, TB).

    Args:
        bytes_value: The number of bytes to format.
        decimal_places: Number of decimal places to show.

    Returns:
        Formatted string (e.g., "1.50 GB").
    """
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if bytes_value < 1024.0:
            return f"{bytes_value:.{decimal_places}f} {unit}"
        bytes_value /= 1024.0
    return f"{bytes_value:.{decimal_places}f} PB"


def has_sufficient_space(path: Union[str, Path], required_bytes: int) -> bool:
    """
    Check if the filesystem has sufficient free space.

    Args:
        path: The path to check.
        required_bytes: The required space in bytes.

    Returns:
        True if sufficient space is available, False otherwise.
    """
    free_space = get_disk_space_free(path)
    return free_space >= required_bytes
