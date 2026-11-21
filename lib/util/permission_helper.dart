import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionHelper {
  PermissionHelper._();

  /// Varmistaa ja pyytää tarvittavat tallennustilaoikeudet (Android 11+ MANAGE_EXTERNAL_STORAGE tai perinteinen STORAGE).
  static Future<bool> pyydaTallennustilaOikeus() async {
    if (!Platform.isAndroid) return true;

    try {
      // 1. Android 11+ (API 30+): Manage External Storage (Kaikkien tiedostojen hallinta)
      final manageStatus = await Permission.manageExternalStorage.status;
      if (manageStatus.isGranted) {
        return true;
      }

      // Pyydetään manageExternalStorage
      final requestResult = await Permission.manageExternalStorage.request();
      if (requestResult.isGranted) {
        return true;
      }

      // 2. Android 10 ja vanhemmat: Storage-oikeus
      final storageStatus = await Permission.storage.status;
      if (storageStatus.isGranted) {
        return true;
      }

      final storageRequestResult = await Permission.storage.request();
      return storageRequestResult.isGranted;
    } catch (e) {
      debugPrint('Virhe tallennusoikeuden pyynnössä: $e');
      return false;
    }
  }

  /// Tarkistaa onko oikeus jo myönnetty ilman kyselyikkunan avaamista
  static Future<bool> onkoTallennustilaOikeus() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await Permission.manageExternalStorage.isGranted) return true;
      if (await Permission.storage.isGranted) return true;
      return false;
    } catch (_) {
      return false;
    }
  }
}
