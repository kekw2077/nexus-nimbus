import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
// Типы приёмника виртуального файла живут здесь: super_drag_and_drop
// их наружу не выносит.
import 'package:super_native_extensions/raw_clipboard.dart';

import '../../core/models/remote_file.dart';
import '../../core/session.dart';

/// Делает строку списка перетаскиваемой наружу — в Проводник, на рабочий стол,
/// в любую папку.
///
/// Windows умеет два способа отдать файл, и клиент пользуется обоими:
///
/// - **готовый файл.** Если локальная копия уже есть, отдаём путь к ней, и
///   Проводник копирует её сам. Ни байта по сети.
/// - **виртуальный файл.** Если копии нет, отдаём обещание: Проводник просит
///   содержимое в момент броска, и только тогда начинается скачивание —
///   сразу в ту папку, куда бросили. Это тот же механизм, которым Outlook
///   отдаёт вложения из письма.
///
/// Папку можно вытащить только скачанную целиком: у виртуального файла нет
/// способа описать дерево, а тянуть папку по одному файлу Проводник не умеет.
class DragOut extends StatelessWidget {
  const DragOut({
    super.key,
    required this.session,
    required this.file,
    required this.child,
  });

  final Session session;
  final RemoteFile file;
  final Widget child;

  Future<DragItem?> _item(DragItemRequest request) async {
    final local = session.vault.localFile(file.path);
    final item = DragItem(localData: file.path, suggestedName: file.name);

    // Папка едет только целиком и только если она уже на диске.
    if (file.isDir) {
      final dir = Directory(local.path);
      if (!await dir.exists()) return null;
      item.add(Formats.fileUri(dir.uri));
      return item;
    }

    if (await local.exists()) {
      item.add(Formats.fileUri(local.uri));
      return item;
    }

    // Размер обязателен: Проводник спрашивает его до того, как начнёт
    // принимать содержимое. Без него отдать нечего.
    if (!item.virtualFileSupported || file.size <= 0) return null;

    item.addVirtualFile(
      format: Formats.plainTextFile,
      provider: (sinkProvider, progress) {
        unawaited(_pour(sinkProvider, progress));
      },
    );
    return item;
  }

  /// Качает файл с сервера прямо в приёмник Проводника.
  Future<void> _pour(
    VirtualFileEventSinkProvider sinkProvider,
    WriteProgress progress,
  ) async {
    EventSink? sink;
    try {
      final source = await session.dav.openRead(file.path);
      final opened = sinkProvider(fileSize: file.size);
      sink = opened;

      var done = 0;
      await for (final chunk in source.stream) {
        opened.add(chunk);
        done += chunk.length;
        progress.updateProgress(done / file.size);
      }
      opened.close();
    } catch (e) {
      // Оборвать приёмник важнее, чем промолчать: иначе Проводник останется
      // ждать содержимое, которого не будет, и подвиснет на полпути.
      sink?.addError(e);
      sink?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DragItemWidget(
      allowedOperations: () => const [DropOperation.copy],
      dragItemProvider: _item,
      child: DraggableWidget(child: child),
    );
  }
}
