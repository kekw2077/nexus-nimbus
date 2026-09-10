import 'package:flutter/material.dart';

/// Размер в привычном виде. Килобайт считаем по 1024 — так же, как их
/// показывает Проводник, иначе цифры не сойдутся с системой.
String formatBytes(int bytes, {int decimals = 1}) {
  if (bytes <= 0) return '0 Б';
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ', 'ПБ'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : (value >= 100 ? 0 : decimals);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Русское склонение после числа: 1 объект, 2 объекта, 5 объектов.
/// Одиннадцать—четырнадцать — исключение, они всегда «объектов».
String plural(int n, String one, String few, String many) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 14) return many;
  return switch (n % 10) { 1 => one, 2 || 3 || 4 => few, _ => many };
}

String formatSpeed(int bytesPerSecond) => '${formatBytes(bytesPerSecond)}/с';

/// Число с разрядами: 50 214 читается с одного взгляда, 50214 — нет.
/// Разделитель неразрывный, чтобы число не переносилось посередине.
String formatCount(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Сколько лежит внутри папки, словами. Считает это сервер
/// (nc:contained-folder-count и nc:contained-file-count) — но не всякий:
/// null означает «сервер не сказал», и это не то же самое, что «пусто».
String? formatContents({int? folders, int? files}) {
  if (folders == null && files == null) return null;
  final d = folders ?? 0;
  final f = files ?? 0;
  final parts = <String>[
    if (d > 0) '$d ${plural(d, 'папка', 'папки', 'папок')}',
    if (f > 0) '$f ${plural(f, 'файл', 'файла', 'файлов')}',
  ];
  return parts.isEmpty ? 'пусто' : parts.join(', ');
}

/// Длительность коротко, для оценки «сколько осталось». Секунды у минут
/// показываем, только пока минут меньше десяти: дальше эта точность всё
/// равно ложная — скорость плавает сильнее, чем эти секунды значат.
String formatDuration(Duration d) {
  final total = d.inSeconds < 1 ? 1 : d.inSeconds;
  if (total < 60) return '$total с';

  final minutes = total ~/ 60;
  if (minutes < 10) {
    final seconds = total % 60;
    return seconds == 0 ? '$minutes мин' : '$minutes мин $seconds с';
  }
  if (minutes < 60) return '$minutes мин';

  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours ч' : '$hours ч $rest мин';
}

const _months = [
  'янв', 'фев', 'мар', 'апр', 'мая', 'июн',
  'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
];

/// Дата так, как её удобно читать в списке: сегодня — время,
/// в этом году — день и месяц, иначе — с годом.
String formatDate(DateTime? when) {
  if (when == null) return '—';
  final now = DateTime.now();
  final time = '${when.hour.toString().padLeft(2, '0')}:'
      '${when.minute.toString().padLeft(2, '0')}';

  final sameDay = when.year == now.year && when.month == now.month && when.day == now.day;
  if (sameDay) return 'сегодня, $time';

  final yesterday = now.subtract(const Duration(days: 1));
  if (when.year == yesterday.year && when.month == yesterday.month && when.day == yesterday.day) {
    return 'вчера, $time';
  }

  final md = '${when.day} ${_months[when.month - 1]}';
  return when.year == now.year ? '$md, $time' : '$md ${when.year}';
}

/// Родовое имя типа файла для колонки «Тип».
String kindOf({required bool isDir, required String extension}) {
  if (isDir) return 'Папка';
  if (extension.isEmpty) return 'Файл';
  return extension.toUpperCase();
}

/// Иконка по расширению. Держим один набор, чтобы список выглядел ровно,
/// когда миниатюр нет — а их нет у большинства файлов.
IconData iconFor({required bool isDir, required String extension, String? mime}) {
  if (isDir) return Icons.folder_rounded;

  const images = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'heic', 'avif', 'tif', 'tiff'};
  const video = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'wmv', 'm4v', 'mpg'};
  const audio = {'mp3', 'flac', 'wav', 'ogg', 'm4a', 'aac', 'opus', 'wma'};
  const archive = {'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso'};
  const code = {
    'dart', 'js', 'ts', 'py', 'rs', 'go', 'c', 'h', 'cpp', 'cs', 'java', 'kt',
    'rb', 'php', 'sh', 'ps1', 'sql', 'json', 'yaml', 'yml', 'xml', 'html', 'css',
  };
  const docs = {'doc', 'docx', 'odt', 'rtf', 'txt', 'md'};
  const sheets = {'xls', 'xlsx', 'ods', 'csv'};
  const slides = {'ppt', 'pptx', 'odp'};

  if (images.contains(extension)) return Icons.image_rounded;
  if (video.contains(extension)) return Icons.movie_rounded;
  if (audio.contains(extension)) return Icons.audiotrack_rounded;
  if (archive.contains(extension)) return Icons.folder_zip_rounded;
  if (code.contains(extension)) return Icons.code_rounded;
  if (docs.contains(extension)) return Icons.description_rounded;
  if (sheets.contains(extension)) return Icons.table_chart_rounded;
  if (slides.contains(extension)) return Icons.slideshow_rounded;
  if (extension == 'pdf') return Icons.picture_as_pdf_rounded;
  if (extension == 'exe' || extension == 'msi') return Icons.terminal_rounded;
  return Icons.insert_drive_file_rounded;
}

/// Стоит ли вообще просить у сервера миниатюру для такого файла.
bool wantsThumbnail(String extension) => const {
      'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'avif', 'tif', 'tiff',
      'mp4', 'mkv', 'mov', 'webm', 'avi',
      'pdf', 'svg',
    }.contains(extension);
