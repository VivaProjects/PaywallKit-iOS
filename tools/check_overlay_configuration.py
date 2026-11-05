#!/usr/bin/env python3
"""Run overlay configuration regression against production Foundation sources."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "Sources/PaywallKit"
files = [
    "Configuration/PaywallCatalog.swift",
    "modules/WebPaywall/WebPaywallConfiguration.swift",
    "modules/WebPaywall/WebPaywallDocument.swift",
    "modules/WebPaywall/WebPaywallSessionPolicy.swift",
    "modules/WebPaywall/WebPaywallJSONValue.swift",
    "modules/WebPaywall/ResourcesCache/WebPaywallPackage.swift",
    "modules/WebPaywall/ResourcesCache/WebPaywallResourceLease.swift",
    "modules/WebPaywall/ResourcesCache/WebPaywallDiskCache.swift",
    "modules/PaywallClient/PaywallHistorySnapshot.swift",
]
with tempfile.TemporaryDirectory(prefix="paywall-overlay-swift-") as temporary:
    binary = str(Path(temporary) / "check-overlay")
    subprocess.run(["swiftc", *[str(source / name) for name in files],
                    str(root / "tools/check_overlay_configuration.swift"),
                    "-module-cache-path", str(Path(temporary) / "modules"), "-o", binary], check=True)
    subprocess.run([binary], check=True)
