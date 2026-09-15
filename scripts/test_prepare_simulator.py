import copy
import subprocess
import unittest
from unittest.mock import patch

import prepare_simulator as simulator

PHONE = {'name': 'iPhone 17 Pro Max', 'identifier': 'phone-max', 'productFamily': 'iPhone'}
RUNTIME = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5', 'version': '26.5',
           'isAvailable': True, 'supportedDeviceTypes': [PHONE]}
UDID = '90726F9B-862D-44D5-A7EE-4A2E5D8E5FE4'
DEVICE = {'name': 'iPhone 17 Pro Max', 'udid': UDID, 'isAvailable': True, 'deviceTypeIdentifier': 'phone-max'}
DATA = {'runtimes': [RUNTIME], 'devicetypes': [PHONE], 'devices': {RUNTIME['identifier']: [DEVICE]}}


class SimulatorPreparationTests(unittest.TestCase):
    def test_existing_available_phone_uses_udid_without_changes(self):
        with patch.object(simulator, 'inventory', return_value=DATA), patch.object(simulator.subprocess, 'run') as run:
            self.assertEqual(simulator.prepare(), f'platform=iOS Simulator,id={UDID}')
            run.assert_not_called()

    def test_different_phone_name_is_supported(self):
        data = copy.deepcopy(DATA)
        data['devices'][RUNTIME['identifier']][0]['name'] = 'iPhone 16e'
        with patch.object(simulator, 'inventory', return_value=data):
            self.assertEqual(simulator.prepare(), f'platform=iOS Simulator,id={UDID}')

    def test_unavailable_runtime_and_device_are_not_selected(self):
        data = copy.deepcopy(DATA)
        newer = dict(RUNTIME, identifier='com.apple.CoreSimulator.SimRuntime.iOS-27-0', version='27.0', isAvailable=False)
        data['runtimes'].append(newer)
        data['devices'][newer['identifier']] = [dict(DEVICE, udid='invalid-runtime')]
        data['devices'][RUNTIME['identifier']].insert(0, dict(DEVICE, isAvailable=False, udid='invalid-device'))
        with patch.object(simulator, 'inventory', return_value=data):
            self.assertEqual(simulator.prepare(), f'platform=iOS Simulator,id={UDID}')

    def test_installed_runtime_without_devices_creates_compatible_iphone(self):
        data = dict(DATA, devices={})
        with patch.object(simulator, 'inventory', return_value=data), patch.object(simulator.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, UDID+'\n')) as run:
            self.assertEqual(simulator.prepare(), f'platform=iOS Simulator,id={UDID}')
            self.assertEqual(run.call_args.args[0], ['xcrun', 'simctl', 'create', 'Finances Test iPhone', 'phone-max', RUNTIME['identifier']])

    def test_local_missing_runtime_does_not_start_a_download(self):
        with patch.object(simulator, 'inventory', return_value={}), patch.object(simulator.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'No available iOS'):
                simulator.prepare()
            run.assert_not_called()

    def test_runtime_versions_sort_numerically(self):
        data = copy.deepcopy(DATA)
        newer = dict(RUNTIME, identifier='com.apple.CoreSimulator.SimRuntime.iOS-26-10', version='26.10')
        data['runtimes'].append(newer)
        data['devices'][newer['identifier']] = [dict(DEVICE, udid='newer')]
        with patch.object(simulator, 'inventory', return_value=data):
            self.assertEqual(simulator.prepare(), 'platform=iOS Simulator,id=newer')


if __name__ == '__main__':
    unittest.main()
