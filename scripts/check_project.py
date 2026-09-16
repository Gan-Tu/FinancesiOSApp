#!/usr/bin/env python3
"""Portable release preflight. Never opens a personal journal or contacts iCloud."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root / 'scripts/check_xcode_capabilities.py')], check=True)
project = (root / 'FinancesiOS.xcodeproj/project.pbxproj').read_text()
assert '/Users/' not in project and 'FinancesAppMock' not in project
assert '.DS_Store' in (root / '.gitignore').read_text()
assert 'dev.gan.FinancesApp.iOS' in project
info = plistlib.loads((root / 'App/Info.plist').read_bytes())
entitlements = plistlib.loads((root / 'App/FinancesMobile.entitlements').read_bytes())
assert info['FinancesCloudKitContainerIdentifier'] == 'iCloud.dev.gan.FinanceApp'
assert entitlements['com.apple.developer.icloud-container-identifiers'] == ['iCloud.dev.gan.FinanceApp']
assert 'remote-notification' in info['UIBackgroundModes']
assert info['ITSAppUsesNonExemptEncryption'] is False
share_info = plistlib.loads((root / 'ShareExtension/Info.plist').read_bytes())
share_entitlements = plistlib.loads((root / 'ShareExtension/FinancesShare.entitlements').read_bytes())
group = ['group.dev.gan.FinancesApp.iOS']
assert entitlements['com.apple.security.application-groups'] == group
assert share_entitlements['com.apple.security.application-groups'] == group
assert share_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.share-services'
assert 'public.image' in share_info['NSExtension']['NSExtensionAttributes']['NSExtensionActivationRule']
assert 'FinancesShareExtension.appex in Embed Foundation Extensions' in project
handoff_type = 'dev.gan.FinancesApp.receipt-handoff'
handoff_declaration = next(item for item in info['UTExportedTypeDeclarations'] if item['UTTypeIdentifier'] == handoff_type)
assert handoff_declaration['UTTypeConformsTo'] == ['public.data']
assert handoff_declaration['UTTypeTagSpecification']['public.filename-extension'] == ['finances-receipt']
assert any(handoff_type in item['LSItemContentTypes'] and item['LSHandlerRank'] == 'Owner' for item in info['CFBundleDocumentTypes'])
for key in ['NSCameraUsageDescription', 'NSPhotoLibraryUsageDescription']:
    assert info.get(key)
assert (root / 'App/PrivacyInfo.xcprivacy').is_file()
assert 'FinancesJournal_v1' in (root / 'Core/CloudKitSyncService.swift').read_text()
for file in root.rglob('*'):
    if any(part in {'.git', 'build', 'DerivedData', '.build'} for part in file.parts) or not file.is_file():
        continue
    assert file.suffix not in ['.p8', '.p12', '.mobileprovision'], f'Private signing material: {file}'
print('Independent project paths, CloudKit contract, privacy and release configuration passed.')
