#!/usr/bin/env python3
"""Run Foundation-only cache integration checks against production Swift sources."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'Sources/PaywallKit'
COMMON = [
    'modules/WebPaywall/WebPaywallDiagnostics.swift',
    'modules/WebPaywall/PaywallLogging.swift',
    'modules/WebPaywall/PaywallLogStore.swift',
    'Configuration/PaywallCatalog.swift',
    'modules/WebPaywall/WebPaywallDocument.swift',
    'modules/WebPaywall/ResourcesCache/WebPaywallPackage.swift',
    'modules/WebPaywall/ResourcesCache/WebPaywallResourceLease.swift',
    'modules/WebPaywall/ResourcesCache/WebPaywallCacheMaintenance.swift',
    'modules/WebPaywall/ResourcesCache/WebPaywallLocalDocumentLoader.swift',
]
CHECKS = {
    'check_timing_diagnostics': [],
    'check_snapshot_restore': [
        'modules/PaywallClient/PaywallFailure.swift',
        'modules/PaywallClient/Query/PaywallQuerySnapshot.swift',
        'modules/PaywallClient/Query/PaywallQuerySnapshotStore.swift',
        'modules/PaywallClient/Query/PaywallQueryPackageArchive.swift',
        'modules/PaywallClient/Query/PaywallQueryArchiveBatch.swift',
        'modules/PaywallClient/Query/PaywallQueryStartup.swift',
    ],
    'check_resource_cache': [
        'modules/WebPaywall/ResourcesCache/WebPaywallResourceCache.swift',
        'modules/WebPaywall/ResourcesCache/WebPaywallResourceDownload.swift',
        'modules/WebPaywall/ResourcesCache/WebPaywallDownloadDelegate.swift',
        'modules/WebPaywall/ResourcesCache/WebPaywallDownloadCancellation.swift',
        'modules/PaywallClient/Query/PaywallQueryRetry.swift',
    ],
}
CHECKS['check_local_package_loading'] = CHECKS['check_resource_cache'] + [
    'modules/PaywallClient/PaywallFailure.swift',
    'modules/PaywallClient/PaywallLocalPackageStore.swift',
    'modules/PaywallClient/PaywallHistoryStore.swift',
    'modules/PaywallClient/PaywallHistorySnapshot.swift',
    'modules/PaywallClient/PaywallFallbackContext.swift',
    'modules/PaywallClient/PaywallSessionResolution.swift',
]

CHECKS['check_query_priority'] = [
    'modules/PaywallClient/Query/PaywallQueryResponse.swift',
    'modules/PaywallClient/Query/PaywallQueryRetry.swift',
]

with tempfile.TemporaryDirectory(prefix='paywall-cache-checks-') as temp:
    for name, files in CHECKS.items():
        binary = str(Path(temp) / name)
        stubs = [str(ROOT / 'tools' / 'local_fallback_stubs.swift')] if name == 'check_local_package_loading' else []
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path',
                        str(Path(temp) / 'modules'),
                        *[str(BASE / file) for file in COMMON + files],
                        *stubs,
                        str(ROOT / 'tools' / 'cache_maintenance_gate.swift'),
                        str(ROOT / 'tools' / f'{name}.swift'), '-o', binary], check=True)
        subprocess.run([binary], check=True, timeout=60)
