#!/usr/bin/env python3
"""Example usage of the disk_space module."""

import argparse
import os
from pathlib import Path

from disk_space import (
    get_disk_space_free,
    get_disk_space_info,
    format_bytes,
    has_sufficient_space,
)


def get_folder_size(folder_path):
    """
    Calculate the total size of a folder and all its contents.

    Args:
        folder_path: Path to the folder to measure.

    Returns:
        Total size in bytes, or 0 if inaccessible.
    """
    total_size = 0
    try:
        for dirpath, dirnames, filenames in os.walk(folder_path):
            for filename in filenames:
                filepath = os.path.join(dirpath, filename)
                try:
                    total_size += os.path.getsize(filepath)
                except (OSError, PermissionError):
                    # Skip files we can't access
                    pass
    except (OSError, PermissionError):
        # Skip folders we can't access
        pass
    return total_size


def get_top_folders(path, top_n=10):
    """
    Get the top N largest subfolders in a given directory.

    Args:
        path: Directory to analyze.
        top_n: Number of top folders to return (default: 10).

    Returns:
        List of tuples (folder_path, size_in_bytes) sorted by size descending.
    """
    folder_sizes = []

    try:
        # Get all immediate subfolders
        with os.scandir(path) as entries:
            for entry in entries:
                if entry.is_dir(follow_symlinks=False):
                    try:
                        size = get_folder_size(entry.path)
                        folder_sizes.append((entry.path, size))
                    except (OSError, PermissionError):
                        # Skip folders we can't access
                        pass
    except (OSError, PermissionError):
        print(f"Error: Cannot access directory {path}")
        return []

    # Sort by size (descending) and return top N
    folder_sizes.sort(key=lambda x: x[1], reverse=True)
    return folder_sizes[:top_n]


def main():
    """Demonstrate disk space checking functionality."""
    parser = argparse.ArgumentParser(
        description="Disk space analyzer - shows disk usage and largest folders"
    )
    parser.add_argument(
        "--path",
        "-p",
        default=".",
        help="Path to analyze (default: current directory)",
    )
    parser.add_argument(
        "--top",
        "-t",
        type=int,
        default=10,
        help="Number of top folders to display (default: 10)",
    )
    parser.add_argument(
        "--no-details",
        action="store_true",
        help="Skip detailed disk space information",
    )

    args = parser.parse_args()
    path = os.path.abspath(args.path)

    if not args.no_details:
        print("=== Disk Space Information ===\n")

        # Get complete disk info
        info = get_disk_space_info(path)

        print(f"Path: {path}")
        print(f"Total space: {format_bytes(info['total'])}")
        print(f"Used space:  {format_bytes(info['used'])}")
        print(f"Free space:  {format_bytes(info['free'])}")

        # Calculate percentage
        used_percent = (info['used'] / info['total']) * 100
        free_percent = (info['free'] / info['total']) * 100

        print(f"\nUsage: {used_percent:.1f}% used, {free_percent:.1f}% free")

        # Check if we have enough space for various file sizes
        print("\n=== Space Availability Checks ===\n")

        test_sizes = [
            (1 * 1024**2, "1 MB"),
            (100 * 1024**2, "100 MB"),
            (1 * 1024**3, "1 GB"),
            (10 * 1024**3, "10 GB"),
            (100 * 1024**3, "100 GB"),
        ]

        for size_bytes, size_name in test_sizes:
            has_space = has_sufficient_space(path, size_bytes)
            status = "✓" if has_space else "✗"
            print(f"{status} Sufficient space for {size_name}: {has_space}")

    # Show top N largest folders
    print(f"\n=== Top {args.top} Largest Subfolders in {path} ===\n")
    print("Analyzing folders (this may take a moment)...\n")

    top_folders = get_top_folders(path, args.top)

    if not top_folders:
        print("No accessible subfolders found or unable to access directory.")
    else:
        for idx, (folder_path, size) in enumerate(top_folders, 1):
            folder_name = os.path.basename(folder_path)
            print(f"{idx:2}. {format_bytes(size):>12} - {folder_name}")
            print(f"    {folder_path}")

        # Show total size of all top folders
        total_top_size = sum(size for _, size in top_folders)
        print(f"\nTotal size of top {len(top_folders)} folders: {format_bytes(total_top_size)}")


if __name__ == "__main__":
    main()
