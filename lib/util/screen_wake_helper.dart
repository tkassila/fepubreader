import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Estää Android-laitteen näytön sammumisen (FLAG_KEEP_SCREEN_ON)
/// raskaiden taustatehtävien (kuten metatietojen skannaus tai tuonti) ajaksi.
class ScreenWakeHelper {
  ScreenWakeHelper._();

  static const MethodChannel _channel =
      MethodChannel('com.metait.fepubreader/screen');

  static int _aktiivisetLukot = 0;

  /// Lisää tai poistaa näytön päälläpitopyynnön.
  /// Näyttö pidetään päällä niin kauan kuin vähintään yksi tehtävä on aktiivisena.
  static Future<void> asetaNayttoPaalle(bool paalla) async {
    if (!Platform.isAndroid) return;

    if (paalla) {
      _aktiivisetLukot++;
      if (_aktiivisetLukot > 1) return;
    } else {
      if (_aktiivisetLukot <= 0) {
        _aktiivisetLukot = 0;
        return;
      }
      _aktiivisetLukot--;
      if (_aktiivisetLukot > 0) return;
    }

    try {
      await _channel.invokeMethod<void>(
        'setKeepScreenOn',
        {'keepOn': _aktiivisetLukot > 0},
      );
    } catch (e) {
      debugPrint('Näytön päälläpidon asetus epäonnistui: $e');
    }
  }
}
