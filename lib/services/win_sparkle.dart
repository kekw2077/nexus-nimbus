import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Прямой вызов WinSparkle в обход пакета auto_updater.
///
/// Пакет отдаёт наружу только два режима, и оба показывают собственное окно
/// «доступно обновление» — нарисованное обычными органами Windows, мимо всего
/// оформления приложения. Нужен третий, который у WinSparkle есть, но в
/// пакет не попал: проверить, скачать и поставить **без этого окна**.
///
/// Так спрашивает человека наше окно, а WinSparkle делает то, ради чего он и
/// взят: качает установщик и сверяет его подпись. Писать скачивание самим
/// значило бы обойти проверку, ради которой заведён ключ.
///
/// Библиотека лежит рядом с исполняемым файлом — её кладёт туда тот же пакет.
class WinSparkle {
  const WinSparkle._();

  static DynamicLibrary? _lib;
  static bool _tried = false;

  /// Загружается лениво и только на Windows: на других системах и в тестах
  /// библиотеки нет, а падать из-за этого нечему.
  static DynamicLibrary? get _library {
    if (_tried) return _lib;
    _tried = true;
    if (!Platform.isWindows) return null;
    try {
      _lib = DynamicLibrary.open('WinSparkle.dll');
    } catch (_) {
      _lib = null;
    }
    return _lib;
  }

  /// Доступен ли обход. Ложь — обновление придётся отдать пакету вместе
  /// с его собственным окном.
  static bool get available => _library != null;

  /// Представляется WinSparkle до его запуска и выключает его собственную
  /// проверку по расписанию. Звать строго **до** `setFeedURL` — внутри неё
  /// плагин делает `win_sparkle_init`, а тот уже читает эти настройки.
  ///
  /// Зачем версия: без неё WinSparkle берёт ProductVersion из ресурсов exe,
  /// а Flutter пишет туда «0.3.3+6» — с номером сборки. Плюс для WinSparkle
  /// не разделитель, а буквенный хвост вроде «beta», и «0.3.3+6» выходит
  /// *старше* чистой «0.3.3» из канала. Так уже установленная версия
  /// предлагалась к установке заново.
  ///
  /// Зачем выключать расписание: пакет умеет только задать интервал, а меньше
  /// часа WinSparkle не принимает — ноль молча превращался в час. Раз в час он
  /// проверял канал сам и показывал своё окно мимо нашего оформления.
  ///
  /// Имя компании и приложения — те же, что в Runner.rc: из них складывается
  /// путь настроек WinSparkle в реестре, менять его незачем.
  ///
  /// Версия — без номера сборки, как отдаёт PackageInfo; `null`, если её
  /// узнать не удалось: тогда WinSparkle остаётся при своей, лишь бы не
  /// подсунуть ему прочерк.
  static bool configure({
    required String? version,
    String company = 'Nexus',
    String app = 'Nexus Nimbus',
  }) {
    final lib = _library;
    if (lib == null) return false;

    try {
      if (version != null && RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) {
        final cCompany = company.toNativeUtf16();
        final cApp = app.toNativeUtf16();
        final cVersion = version.toNativeUtf16();
        try {
          lib.lookupFunction<
              Void Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>),
              void Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>)>(
            'win_sparkle_set_app_details',
          )(cCompany, cApp, cVersion);
        } finally {
          calloc.free(cCompany);
          calloc.free(cApp);
          calloc.free(cVersion);
        }
      }

      lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'win_sparkle_set_automatic_check_for_updates',
      )(0);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Проверить, скачать и поставить, не показывая окна «доступно обновление».
  ///
  /// Окно с ходом скачивания WinSparkle всё же покажет — его отключить
  /// нельзя, да и незачем: пока идёт загрузка, человеку полезно её видеть.
  static bool checkAndInstall() {
    final lib = _library;
    if (lib == null) return false;
    try {
      lib.lookupFunction<Void Function(), void Function()>(
        'win_sparkle_check_update_with_ui_and_install',
      )();
      return true;
    } catch (_) {
      // Символа нет — библиотека другой версии. Пусть решает вызывающий.
      return false;
    }
  }
}
