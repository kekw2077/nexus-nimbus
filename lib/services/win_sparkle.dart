import 'dart:ffi';
import 'dart:io';

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
