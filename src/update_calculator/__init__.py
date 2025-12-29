"""
Update Calculator Module

Provides functionality for computing available package updates by comparing
installed packages against mirrored repository content.
"""

from .calculator import UpdateCalculator
from .rpm_utils import RPMVersion, compare_versions, parse_nevra

__all__ = [
    "UpdateCalculator",
    "RPMVersion",
    "compare_versions",
    "parse_nevra",
]

__version__ = "1.0.0"
