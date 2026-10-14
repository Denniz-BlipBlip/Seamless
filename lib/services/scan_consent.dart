import 'package:shared_preferences/shared_preferences.dart';

/// Remembers that the user agreed to the scan terms, so the question is
/// asked only once on this device.
abstract interface class ScanConsentStore {
  Future<bool> isGranted();

  Future<void> grant();
}

class PreferencesScanConsentStore implements ScanConsentStore {
  static const _key = 'seamly.scan_consent_v1';

  @override
  Future<bool> isGranted() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_key) ?? false;
  }

  @override
  Future<void> grant() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_key, true);
  }
}

class MemoryScanConsentStore implements ScanConsentStore {
  MemoryScanConsentStore({bool granted = false}) : _granted = granted;

  bool _granted;

  @override
  Future<bool> isGranted() async => _granted;

  @override
  Future<void> grant() async => _granted = true;
}
