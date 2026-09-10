import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:nexus_nimbus/core/format.dart';
import 'package:nexus_nimbus/core/models/cloud_provider.dart';
import 'package:nexus_nimbus/core/models/remote_file.dart';
import 'package:nexus_nimbus/services/sync_engine.dart';
import 'package:nexus_nimbus/services/updater.dart';
import 'package:nexus_nimbus/services/transfer_queue.dart';
import 'package:nexus_nimbus/services/webdav_client.dart';

/// Ответ вида, который отдаёт Nextcloud: пути в процентной записи,
/// префиксы d:/oc:/nc:, первая запись — сама папка.
const _multistatus = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"
               xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/art/%D0%94%D0%BE%D0%BA%D1%83%D0%BC%D0%B5%D0%BD%D1%82%D1%8B/</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>Fri, 05 Sep 2026 09:11:04 GMT</d:getlastmodified>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getetag>&quot;68bb1e8873f2c&quot;</d:getetag>
        <oc:fileid>12</oc:fileid>
        <oc:size>4096</oc:size>
        <oc:permissions>RGDNVCK</oc:permissions>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/art/%D0%94%D0%BE%D0%BA%D1%83%D0%BC%D0%B5%D0%BD%D1%82%D1%8B/%D0%BE%D1%82%D1%87%D1%91%D1%82%20%E2%84%961.pdf</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>Fri, 05 Sep 2026 10:00:00 GMT</d:getlastmodified>
        <d:getcontentlength>204800</d:getcontentlength>
        <d:getcontenttype>application/pdf</d:getcontenttype>
        <d:getetag>&quot;abc123&quot;</d:getetag>
        <d:resourcetype/>
        <oc:fileid>34</oc:fileid>
        <oc:permissions>RGDNVW</oc:permissions>
        <oc:favorite>1</oc:favorite>
        <nc:has-preview>true</nc:has-preview>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop><oc:size/></d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

/// Ответ с расширенными свойствами: то, что Nextcloud отдаёт сверх
/// обычного PROPFIND — виды раздачи, счётчики содержимого, контрольные
/// суммы, даты создания и заливки, блокировка.
const _extended = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/art/Проекты/</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <oc:fileid>77</oc:fileid>
        <oc:size>8192</oc:size>
        <oc:permissions>RGDNVCK</oc:permissions>
        <oc:share-types>
          <oc:share-type>3</oc:share-type>
          <oc:share-type>0</oc:share-type>
          <oc:share-type>3</oc:share-type>
        </oc:share-types>
        <nc:contained-folder-count>2</nc:contained-folder-count>
        <nc:contained-file-count>7</nc:contained-file-count>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/art/Проекты/смета.xlsx</d:href>
    <d:propstat>
      <d:prop>
        <d:getcontentlength>51200</d:getcontentlength>
        <d:resourcetype/>
        <oc:fileid>78</oc:fileid>
        <oc:permissions>RGDNVW</oc:permissions>
        <oc:checksums>
          <oc:checksum>SHA1:0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33</oc:checksum>
          <oc:checksum>MD5:900150983cd24fb0d6963f7d28e17f72</oc:checksum>
        </oc:checksums>
        <nc:creation_time>1756000000</nc:creation_time>
        <nc:upload_time>1757000000</nc:upload_time>
        <nc:lock>1</nc:lock>
        <nc:lock-owner>art</nc:lock-owner>
        <nc:lock-owner-displayname>Артём</nc:lock-owner-displayname>
        <nc:lock-owner-type>0</nc:lock-owner-type>
        <nc:lock-time>1757000000</nc:lock-time>
        <nc:lock-timeout>1800</nc:lock-timeout>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/files/art/Проекты/черновик.txt</d:href>
    <d:propstat>
      <d:prop>
        <d:getcontentlength>120</d:getcontentlength>
        <d:resourcetype/>
        <oc:fileid>79</oc:fileid>
        <oc:permissions>RGDNVW</oc:permissions>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop>
        <oc:checksums/><nc:lock/><nc:creation_time/>
        <nc:contained-file-count/>
      </d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

/// Ответ корзины: служебное имя с хвостом .d<время>, настоящее имя и
/// исходное расположение в отдельных свойствах, время удаления — unix.
const _trash = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/trashbin/art/trash/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/art/trash/%D0%BE%D1%82%D1%87%D1%91%D1%82.pdf.d1757068800</d:href>
    <d:propstat>
      <d:prop>
        <d:getcontentlength>2048</d:getcontentlength>
        <d:getcontenttype>application/pdf</d:getcontenttype>
        <d:resourcetype/>
        <oc:fileid>77</oc:fileid>
        <nc:trashbin-filename>&#x43E;&#x442;&#x447;&#x451;&#x442;.pdf</nc:trashbin-filename>
        <nc:trashbin-original-location>&#x414;&#x43E;&#x43A;&#x443;&#x43C;&#x435;&#x43D;&#x442;&#x44B;/&#x43E;&#x442;&#x447;&#x451;&#x442;.pdf</nc:trashbin-original-location>
        <nc:trashbin-deletion-time>1757068800</nc:trashbin-deletion-time>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/trashbin/art/trash/archive.d1757000000</d:href>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <oc:size>50000</oc:size>
        <nc:trashbin-original-location>archive</nc:trashbin-original-location>
        <nc:trashbin-deletion-time>1757000000</nc:trashbin-deletion-time>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>""";

void main() {
  group('разбор multistatus', () {
    // /remote.php/dav/files/art → четыре сегмента до пользовательских путей.
    final parsed = WebDavClient.parseMultistatus(
      Uint8List.fromList(utf8.encode(_multistatus)),
      4,
    );

    test('возвращает и папку, и файл', () {
      expect(parsed, hasLength(2));
    });

    test('раскодирует кириллицу и пробелы в путях', () {
      expect(parsed[0].path, 'Документы');
      expect(parsed[1].path, 'Документы/отчёт №1.pdf');
      expect(parsed[1].name, 'отчёт №1.pdf');
    });

    test('различает папку и файл', () {
      expect(parsed[0].isDir, isTrue);
      expect(parsed[1].isDir, isFalse);
    });

    test('для папки берёт oc:size, для файла — getcontentlength', () {
      expect(parsed[0].size, 4096);
      expect(parsed[1].size, 204800);
    });

    test('снимает кавычки с etag и читает служебные свойства', () {
      expect(parsed[1].etag, 'abc123');
      expect(parsed[1].fileId, '34');
      expect(parsed[1].favorite, isTrue);
      expect(parsed[1].hasPreview, isTrue);
      expect(parsed[1].mimeType, 'application/pdf');
    });

    test('игнорирует propstat со статусом, отличным от 200', () {
      // oc:size пришёл в блоке 404 — для файла он не должен подменить размер.
      expect(parsed[1].size, isNot(0));
    });

    test('разбирает права доступа', () {
      expect(parsed[1].canDelete, isTrue);
      expect(parsed[1].canWrite, isTrue);
      expect(parsed[0].canRename, isTrue);
    });

    test('переводит дату из RFC 1123', () {
      expect(parsed[1].modified?.toUtc(), DateTime.utc(2026, 9, 5, 10));
    });
  });

  group('разбор расширенных свойств', () {
    final parsed = WebDavClient.parseMultistatus(
      Uint8List.fromList(utf8.encode(_extended)),
      4,
    );
    final folder = parsed[0];
    final locked = parsed[1];
    final plain = parsed[2];

    test('виды раздачи разбираются и не двоятся', () {
      // В ответе share-type 3 встречается дважды — способ один и тот же.
      expect(folder.shareTypes, containsAll([ShareKind.link, ShareKind.user]));
      expect(folder.shareTypes, hasLength(2));
      expect(folder.isSharedOut, isTrue);
    });

    test('счётчики содержимого читаются у папки', () {
      expect(folder.folderCount, 2);
      expect(folder.fileCount, 7);
      expect(folder.hasCounts, isTrue);
    });

    test('суммы из отдельных элементов не склеиваются', () {
      expect(locked.checksums.sha1, '0beec7b5ea3f0fdbc95d0dd47f3c5bc275da8a33');
      expect(locked.checksums.md5, '900150983cd24fb0d6963f7d28e17f72');
      expect(locked.checksums.preferred?.type, 'SHA1');
    });

    test('даты создания и заливки — это разные даты', () {
      expect(locked.created?.toUtc(), DateTime.fromMillisecondsSinceEpoch(1756000000 * 1000, isUtc: true));
      expect(locked.uploaded?.toUtc(), DateTime.fromMillisecondsSinceEpoch(1757000000 * 1000, isUtc: true));
      expect(locked.created, isNot(locked.uploaded));
    });

    test('блокировка разбирается вместе с владельцем и сроком', () {
      final lock = locked.lock;
      expect(lock, isNotNull);
      expect(lock!.who, 'Артём');
      expect(lock.owner, 'art');
      expect(lock.byApp, isFalse);
      expect(lock.timeout, const Duration(minutes: 30));
      expect(lock.expiresAt, lock.since!.add(const Duration(minutes: 30)));
    });

    test('своя блокировка отличается от чужой, регистр не мешает', () {
      final lock = locked.lock!;
      expect(lock.byMe('ART'), isTrue);
      expect(lock.byMe('kate'), isFalse);
      expect(lock.byMe(null), isFalse);
    });

    test('без свойств запись остаётся пустой, а не выдуманной', () {
      // Свойства пришли в блоке 404 — значит, сервер их не знает.
      expect(plain.checksums.isEmpty, isTrue);
      expect(plain.lock, isNull);
      expect(plain.isLocked, isFalse);
      expect(plain.created, isNull);
      expect(plain.folderCount, isNull);
      expect(plain.hasCounts, isFalse);
      expect(plain.shareTypes, isEmpty);
    });
  });

  group('контрольные суммы', () {
    test('разбирают строку с несколькими алгоритмами', () {
      final c = Checksums.parse('SHA1:AABBCC MD5:DDEEFF');
      expect(c.sha1, 'aabbcc');
      expect(c.md5, 'ddeeff');
    });

    test('пустое и мусорное не роняют разбор', () {
      expect(Checksums.parse(null).isEmpty, isTrue);
      expect(Checksums.parse('   ').isEmpty, isTrue);
      expect(Checksums.parse('SHA1:').isEmpty, isTrue);
      expect(Checksums.parse(':abc').isEmpty, isTrue);
    });

    test('без SHA1 сверяемся по MD5', () {
      expect(Checksums.parse('MD5:abc').preferred?.type, 'MD5');
      expect(Checksums.parse('ADLER32:abc').preferred, isNull);
    });
  });

  group('форматирование', () {
    test('разряды в больших числах разделяются', () {
      expect(formatCount(7), '7');
      expect(formatCount(999), '999');
      expect(formatCount(50214), '50\u00A0214');
      expect(formatCount(1234567), '1\u00A0234\u00A0567');
    });

    test('размеры считаются по 1024', () {
      expect(formatBytes(0), '0 Б');
      expect(formatBytes(512), '512 Б');
      expect(formatBytes(1024), '1.0 КБ');
      expect(formatBytes(1536), '1.5 КБ');
      expect(formatBytes(1024 * 1024 * 3), '3.0 МБ');
    });

    test('крупные значения показываются без дробной части', () {
      expect(formatBytes(1024 * 1024 * 512), '512 МБ');
    });

    test('скорость — тот же размер с хвостом', () {
      expect(formatSpeed(1024 * 1024 * 3), '3.0 МБ/с');
    });

    test('длительность: секунды, минуты, часы', () {
      expect(formatDuration(const Duration(seconds: 12)), '12 с');
      expect(formatDuration(const Duration(minutes: 3, seconds: 5)), '3 мин 5 с');
      expect(formatDuration(const Duration(minutes: 3)), '3 мин');
      expect(formatDuration(const Duration(hours: 1, minutes: 20)), '1 ч 20 мин');
      expect(formatDuration(const Duration(hours: 2)), '2 ч');
    });

    test('длительность: у долгих оценок секунды отбрасываются', () {
      // Дальше десяти минут точность до секунды всё равно ложная.
      expect(formatDuration(const Duration(minutes: 42, seconds: 30)), '42 мин');
    });

    test('длительность: меньше секунды показывается как секунда', () {
      expect(formatDuration(Duration.zero), '1 с');
      expect(formatDuration(const Duration(milliseconds: 200)), '1 с');
    });
  });

  group('пачка передач', () {
    TransferBatch makeBatch() => TransferBatch(
          id: 1,
          kind: TransferKind.upload,
          label: 'Nexus Anima',
          remoteRoot: 'проекты/Nexus Anima',
        );

    TransferTask makeFile(TransferBatch batch, int id, int size) => TransferTask(
          id: id,
          kind: TransferKind.upload,
          remotePath: 'проекты/Nexus Anima/файл$id.dart',
          local: File('файл$id.dart'),
          batch: batch,
          total: size,
        );

    test('пока идёт обход, пачка жива даже без задач', () {
      // Иначе только что открытая пачка считалась бы законченной и
      // исчезала бы из списка, не начавшись.
      final batch = makeBatch();
      expect(batch.files, 0);
      expect(batch.isActive, isTrue);
      expect(batch.scanning, isTrue);

      batch.scanning = false;
      expect(batch.isActive, isFalse);
    });

    test('счёт файлов и байтов растёт по мере обхода', () {
      final batch = makeBatch();
      batch.noteAdded(makeFile(batch, 1, 100));
      batch.noteAdded(makeFile(batch, 2, 300));

      expect(batch.files, 2);
      expect(batch.bytesTotal, 400);
      expect(batch.filesLeft, 2);
      expect(batch.startedAt, isNotNull);
    });

    test('завершённой задаче засчитывается весь размер', () {
      // Последний отрезок прогресса может не прийти, а файл при этом
      // уехал целиком — иначе пачка навсегда застревала бы на 99%.
      final batch = makeBatch()..scanning = false;
      final task = makeFile(batch, 1, 1000)..done = 940;
      batch.noteAdded(task);
      batch.noteSettled(task, TransferState.done);

      expect(batch.bytesDone, 1000);
      expect(batch.fraction, 1.0);
      expect(batch.filesDone, 1);
      expect(batch.isActive, isFalse);
      expect(batch.state, TransferState.done);
    });

    test('идущие задачи считаются отдельно от закрытых', () {
      final batch = makeBatch()..scanning = false;
      final first = makeFile(batch, 1, 1000);
      final second = makeFile(batch, 2, 1000)..done = 250;
      batch..noteAdded(first)..noteAdded(second);
      batch.noteSettled(first, TransferState.done);
      batch.noteRunning(second);

      expect(batch.bytesDone, 1250);
      expect(batch.fraction, closeTo(0.625, 0.001));
      expect(batch.filesLeft, 1);
      expect(batch.state, TransferState.running);
    });

    test('пока идёт обход, срок не обещается', () {
      // Знаменатель ещё растёт: обещанные пять минут превратились бы
      // в час, и лучше промолчать.
      final batch = makeBatch();
      batch.noteAdded(makeFile(batch, 1, 1000));
      expect(batch.remaining, isNull);
    });

    test('неудачи копятся, но список не растёт без предела', () {
      final batch = makeBatch()..scanning = false;
      for (var i = 0; i < TransferBatch.maxFailures + 20; i++) {
        final task = makeFile(batch, i, 10);
        batch.noteAdded(task);
        batch.noteSettled(task, TransferState.failed);
      }

      expect(batch.filesFailed, TransferBatch.maxFailures + 20);
      expect(batch.failures, hasLength(TransferBatch.maxFailures));
      expect(batch.state, TransferState.failed);
    });

    test('отменённая пачка остаётся отменённой, даже если часть уехала', () {
      final batch = makeBatch()..scanning = false;
      final ok = makeFile(batch, 1, 100);
      final stopped = makeFile(batch, 2, 100);
      batch..noteAdded(ok)..noteAdded(stopped);
      batch.noteSettled(ok, TransferState.done);
      batch.noteSettled(stopped, TransferState.cancelled);
      batch.cancelled = true;

      expect(batch.filesDone, 1);
      expect(batch.state, TransferState.cancelled);
      expect(batch.isActive, isFalse);
    });

    test('россыпь файлов — пачка без папки', () {
      final batch = TransferBatch(id: 2, kind: TransferKind.download, label: '12 файлов');
      expect(batch.isFolder, isFalse);
      expect(batch.remoteRoot, isNull);
    });
  });

  group('замер скорости передачи', () {
    TransferTask makeTask() => TransferTask(
          id: 1,
          kind: TransferKind.download,
          remotePath: 'файл.bin',
          local: File('файл.bin'),
          total: 1000,
        );

    test('первый замер только запоминает точку отсчёта', () {
      final task = makeTask();
      task.sample(0);
      expect(task.bytesPerSecond, 0);
      expect(task.remaining, isNull);
    });

    test('замеры чаще окна не учитываются', () {
      // Иначе скорость считалась бы по одному чанку и мигала бы на экране.
      final task = makeTask();
      task.sample(0);
      task.sample(500);
      expect(task.bytesPerSecond, 0);
    });

    test('остаток считается от переданного', () {
      final task = makeTask()..done = 400;
      expect(task.left, 600);
    });

    test('у задачи с неизвестным размером остатка нет', () {
      final task = TransferTask(
        id: 2,
        kind: TransferKind.upload,
        remotePath: 'файл.bin',
        local: File('файл.bin'),
      );
      task.done = 400;
      expect(task.left, 0);
      expect(task.fraction, 0);
      expect(task.remaining, isNull);
    });

    test('средняя скорость считается по времени всей передачи', () {
      final task = makeTask()
        ..done = 1000
        ..startedAt = DateTime(2026, 9, 6, 12, 0, 0)
        ..finishedAt = DateTime(2026, 9, 6, 12, 0, 2);
      expect(task.averageSpeed, 500);
    });

    test('средней скорости нет, пока передача не закончилась', () {
      final task = makeTask()..startedAt = DateTime(2026, 9, 6, 12);
      expect(task.averageSpeed, 0);
    });
  });

  group('разбор корзины', () {
    // /remote.php/dav/trashbin/art -> четыре сегмента, плюс сам trash.
    final items = WebDavClient.parseTrash(
      Uint8List.fromList(utf8.encode(_trash)),
      5,
    );

    test('саму папку trash в список не кладёт', () {
      expect(items, hasLength(2));
    });

    test('показывает настоящее имя, а не служебное с хвостом .d<время>', () {
      expect(items[0].name, 'отчёт.pdf');
      expect(items[0].id, 'отчёт.pdf.d1757068800');
    });

    test('запоминает, откуда файл удалили', () {
      expect(items[0].originalLocation, 'Документы/отчёт.pdf');
      expect(items[0].restoreFolder, 'Документы');
      // Удалённое из корня возвращается в корень.
      expect(items[1].restoreFolder, '');
    });

    test('размер берёт из getcontentlength, у папки — из oc:size', () {
      expect(items[0].size, 2048);
      expect(items[1].size, 50000);
      expect(items[1].isDir, isTrue);
    });

    test('время удаления переводит из unix-секунд', () {
      // 1757068800 -> 5 сентября 2025, 10:40 UTC.
      expect(items[0].deletedAt?.toUtc(), DateTime.utc(2025, 9, 5, 10, 40));
    });
  });

  group('разбор версий', () {
    // /remote.php/dav/versions/art/versions/312 — шесть сегментов вместе
    // с самой папкой версий, седьмой сегмент и есть версия.
    final versions = WebDavClient.parseVersions(
        Uint8List.fromList(utf8.encode(_versionsXml)), 6);

    test('саму папку версий в список не кладёт', () {
      expect(versions.length, 2);
      expect(versions.map((v) => v.id), containsAll(['1757068800', '1756982400']));
    });

    test('размер и тип берутся из свойств', () {
      final v = versions.firstWhere((v) => v.id == '1757068800');
      expect(v.size, 2048);
      expect(v.mimeType, 'text/plain');
    });

    test('подпись версии читается, если её задавали', () {
      expect(versions.firstWhere((v) => v.id == '1757068800').label, 'перед правкой');
      expect(versions.firstWhere((v) => v.id == '1756982400').label, isNull);
    });

    test('без даты в свойствах время берётся из самого идентификатора', () {
      // Идентификатор версии — это unix-время, когда её сняли.
      final v = versions.firstWhere((v) => v.id == '1756982400');
      expect(v.savedAt, isNull);
      expect(v.when, DateTime.fromMillisecondsSinceEpoch(1756982400 * 1000,
              isUtc: true)
          .toLocal());
    });

    test('propstat с не-200 статусом пропускается', () {
      // У самой папки версий сервер отдаёт 404 на getcontentlength.
      expect(versions.any((v) => v.id == '312'), isFalse);
    });
  });

  group('синхронизация: что обходим стороной', () {
    test('временные файлы редакторов не уезжают на сервер', () {
      expect(SyncEngine.isSkipped(r'~$отчёт.docx'), isTrue);
      expect(SyncEngine.isSkipped('.~lock.таблица.ods#'), isTrue);
      expect(SyncEngine.isSkipped('черновик.tmp'), isTrue);
      expect(SyncEngine.isSkipped('фильм.mp4.crdownload'), isTrue);
    });

    test('служебный мусор системы тоже', () {
      expect(SyncEngine.isSkipped('Thumbs.db'), isTrue);
      expect(SyncEngine.isSkipped('desktop.ini'), isTrue);
      expect(SyncEngine.isSkipped('.DS_Store'), isTrue);
    });

    test('свои же отложенные копии не уходят на сервер', () {
      // Иначе каждое расхождение плодило бы на сервере копию.
      expect(
        SyncEngine.isSkipped('отчёт (конфликт 2026-09-06 14-30-12).docx'),
        isTrue,
      );
    });

    test('обычные файлы проходят', () {
      expect(SyncEngine.isSkipped('отчёт.docx'), isFalse);
      expect(SyncEngine.isSkipped('фильм.mp4'), isFalse);
      // Похоже на временный, но не он: тильда и доллар должны стоять в начале.
      expect(SyncEngine.isSkipped(r'смета ~$ черновик.xlsx'), isFalse);
    });
  });

  group('синхронизация: имя отложенной копии', () {
    final at = DateTime(2026, 9, 6, 14, 30, 12);

    // Сверяем имя и папку по отдельности: разделитель пути свой на каждой
    // системе, и приколачивать его в ожидании теста незачем.
    test('дата встаёт перед расширением', () {
      final out = SyncEngine.conflictName(p.join('дом', 'отчёт.docx'), at);
      expect(p.basename(out), 'отчёт (конфликт 2026-09-06 14-30-12).docx');
      expect(p.dirname(out), 'дом');
    });

    test('файл без расширения тоже переживает', () {
      final out = SyncEngine.conflictName(p.join('дом', 'README'), at);
      expect(p.basename(out), 'README (конфликт 2026-09-06 14-30-12)');
    });

    test('одноразрядные числа дополняются нулём', () {
      final out = SyncEngine.conflictName(
          p.join('дом', 'a.txt'), DateTime(2026, 1, 2, 3, 4, 5));
      expect(p.basename(out), 'a (конфликт 2026-01-02 03-04-05).txt');
    });

    test('получившееся имя само попадает в исключения', () {
      // Иначе следующий обход принял бы отложенную копию за новый файл.
      expect(
        SyncEngine.isSkipped(p.basename(SyncEngine.conflictName(p.join('дом', 'a.txt'), at))),
        isTrue,
      );
    });
  });

  group('разбор канала обновлений', () {
    final releases = UpdaterService.parseAppcast(utf8.encode(_appcastXml));

    test('читает все записи с установщиком', () {
      expect(releases.length, 2);
      expect(releases.map((r) => r.version), ['0.2.0', '0.1.0']);
    });

    test('новые версии идут первыми', () {
      expect(releases.first.version, '0.2.0');
    });

    test('адрес установщика и размер берутся из enclosure', () {
      final latest = releases.first;
      expect(latest.installerUrl, endsWith('NexusNimbus-Setup-0.2.0.exe'));
      expect(latest.size, 24000000);
    });

    test('дата RFC 822 переводится во время', () {
      // DateTime.parse такую запись не берёт — разбираем сами.
      expect(releases.first.publishedAt?.toUtc(),
          DateTime.utc(2026, 9, 5, 18, 40, 0));
    });

    test('список изменений достаётся из описания выпуска', () {
      // Описание — кусок HTML; нам нужны строчки списка, которые туда
      // кладёт release.ps1, а не разметка вокруг них.
      final latest = releases.first;
      expect(latest.notes, ['Корзина сервера', 'Папка хранилища']);
    });

    test('символьные ссылки в заметках возвращаются на место', () {
      expect(releases.last.notes, ['Кавычки «ёлочки» и амперсанд &']);
    });

    test('запись без установщика пропускается', () {
      // Черновик выпуска в канале ещё не на что скачивать.
      expect(releases.any((r) => r.version == '0.3.0'), isFalse);
    });
  });

  group('сравнение версий', () {
    test('считает по числам, а не по строкам', () {
      // Строкой 0.10.0 оказалась бы младше 0.9.0 — и откат предложил бы не то.
      expect(ReleaseEntry.compare('0.10.0', '0.9.0'), greaterThan(0));
      expect(ReleaseEntry.compare('1.0.0', '0.99.9'), greaterThan(0));
      expect(ReleaseEntry.compare('0.2.0', '0.2.0'), 0);
    });

    test('разная длина номера не мешает', () {
      expect(ReleaseEntry.compare('0.2', '0.2.0'), 0);
      expect(ReleaseEntry.compare('0.2.1', '0.2'), greaterThan(0));
    });

    test('хвост сборки не сбивает сравнение', () {
      expect(ReleaseEntry.compare('0.2.0+2', '0.2.0+1'), greaterThan(0));
    });
  });

  group('облака: адреса и возможности', () {
    NxAccount account(CloudProvider provider, {String login = 'art'}) => NxAccount(
          baseUrl: provider.fixedServer ?? Uri.parse('https://cloud.example.com'),
          loginName: login,
          appPassword: 'secret',
          provider: provider,
        );

    test('у Nextcloud файлы лежат под remote.php/dav/files/{user}', () {
      final dav = WebDavClient(account(CloudProvider.nextcloud));
      expect(
        dav.fileUri('Документы/смета.xlsx').path,
        '/remote.php/dav/files/art/%D0%94%D0%BE%D0%BA%D1%83%D0%BC%D0%B5%D0%BD%D1%82%D1%8B/'
        '%D1%81%D0%BC%D0%B5%D1%82%D0%B0.xlsx',
      );
      dav.close();
    });

    test('у облаков с REST своего корня в адресе нет', () {
      // Путь после базового адреса нужен только тем, кто говорит WebDAV.
      expect(CloudProvider.yandex.filesRoot('art'), isEmpty);
      expect(CloudProvider.google.filesRoot('art'), isEmpty);
    });

    test('расширения Nextcloud есть только у Nextcloud', () {
      for (final v in [CloudProvider.yandex, CloudProvider.google]) {
        expect(v.hasFavorites, isFalse, reason: v.label);
        expect(v.hasVersions, isFalse, reason: v.label);
        expect(v.hasChunkedUpload, isFalse, reason: v.label);
        expect(v.hasSearch, isFalse, reason: v.label);
        expect(v.hasBrowserLogin, isFalse, reason: v.label);
        expect(v.hasLinkOptions, isFalse, reason: v.label);
      }
      expect(CloudProvider.nextcloud.hasFavorites, isTrue);
      expect(CloudProvider.nextcloud.hasSearch, isTrue);
    });

    test('у Яндекса по REST есть корзина, миниатюры и ссылки', () {
      // Ради этого и ушли с WebDAV: по нему у Яндекса ничего этого нет,
      // да и сам он оставлен платным подпискам.
      expect(CloudProvider.yandex.hasTrash, isTrue);
      expect(CloudProvider.yandex.hasPreviews, isTrue);
      expect(CloudProvider.yandex.hasShares, isTrue);
      // Но пароль у ссылки Диск не принимает — только включить и выключить.
      expect(CloudProvider.yandex.hasLinkOptions, isFalse);
    });

    test('у Google Drive нет ни корзины, ни миниатюр, ни ссылок', () {
      expect(CloudProvider.google.hasTrash, isFalse);
      expect(CloudProvider.google.hasPreviews, isFalse);
      expect(CloudProvider.google.hasShares, isFalse);
    });

    test('паролем входим только в Nextcloud, к остальным — через браузер', () {
      expect(CloudProvider.nextcloud.hasPasswordLogin, isTrue);
      expect(CloudProvider.nextcloud.needsOAuth, isFalse);

      for (final v in [CloudProvider.yandex, CloudProvider.google]) {
        expect(v.hasPasswordLogin, isFalse, reason: v.label);
        expect(v.needsOAuth, isTrue, reason: v.label);
        // Приложение регистрируется у облака — адрес должен быть под рукой.
        expect(v.consoleUrl, isNotEmpty, reason: v.label);
      }
    });

    test('имя облака переживает запись и чтение', () {
      for (final v in CloudProvider.values) {
        expect(CloudProvider.byName(v.name), v);
      }
      // Записи прежних версий поля не имели — они все из Nextcloud.
      expect(CloudProvider.byName(null), CloudProvider.nextcloud);
      expect(CloudProvider.byName('чепуха'), CloudProvider.nextcloud);
    });
  });

  group('учётная запись: имя и хранилище', () {
    NxAccount make({
      CloudProvider provider = CloudProvider.nextcloud,
      String host = 'cloud.example.com',
      String login = 'art',
      String password = 'secret',
    }) =>
        NxAccount(
          baseUrl: Uri.parse('https://$host'),
          loginName: login,
          appPassword: password,
          provider: provider,
        );

    test('смена пароля не делает запись другой', () {
      // Иначе после смены пароля хранилище оказалось бы пустым.
      expect(make().id, make(password: 'другой').id);
    });

    test('разные облака, хосты и логины — разные записи', () {
      expect(make().id, isNot(make(provider: CloudProvider.yandex).id));
      expect(make().id, isNot(make(host: 'other.example.com').id));
      expect(make().id, isNot(make(login: 'kate').id));
    });

    test('имя папки не содержит ничего, что путь не переживёт', () {
      final slug = make().slug;
      expect(slug, isNot(contains('/')));
      expect(slug, isNot(contains(':')));
      expect(slug, matches(RegExp(r'^[A-Za-z0-9._-]+$')));
    });

    test('у записей с разными облаками папки тоже разные', () {
      expect(make().slug, isNot(make(provider: CloudProvider.yandex).slug));
    });

    test('облако переживает запись в JSON и чтение обратно', () {
      final back = NxAccount.fromJson(make(provider: CloudProvider.yandex).toJson());
      expect(back.provider, CloudProvider.yandex);
      expect(back.id, make(provider: CloudProvider.yandex).id);
    });
  });

  group('содержимое папки словами', () {
    test('склоняет и папки, и файлы', () {
      expect(formatContents(folders: 1, files: 1), '1 папка, 1 файл');
      expect(formatContents(folders: 2, files: 7), '2 папки, 7 файлов');
      expect(formatContents(folders: 0, files: 3), '3 файла');
    });

    test('пусто и «сервер не сказал» — разные вещи', () {
      expect(formatContents(folders: 0, files: 0), 'пусто');
      expect(formatContents(), isNull);
    });
  });

  group('склонение', () {
    test('единственное, малое и множественное число', () {
      expect(plural(1, 'объект', 'объекта', 'объектов'), 'объект');
      expect(plural(3, 'объект', 'объекта', 'объектов'), 'объекта');
      expect(plural(7, 'объект', 'объекта', 'объектов'), 'объектов');
      expect(plural(21, 'объект', 'объекта', 'объектов'), 'объект');
    });

    test('одиннадцать—четырнадцать — исключение', () {
      for (final n in [11, 12, 13, 14, 112]) {
        expect(plural(n, 'объект', 'объекта', 'объектов'), 'объектов',
            reason: 'n = $n');
      }
    });
  });
}

/// Ответ дерева версий: первой записью идёт сама папка версий — со статусом
/// 404 на запрошенные свойства, дальше сами версии.
const _versionsXml = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns"
               xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/versions/art/versions/312/</d:href>
    <d:propstat>
      <d:prop><d:getcontentlength/><d:getlastmodified/></d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/art/versions/312/1757068800</d:href>
    <d:propstat>
      <d:prop>
        <d:getcontentlength>2048</d:getcontentlength>
        <d:getlastmodified>Fri, 05 Sep 2026 12:00:00 GMT</d:getlastmodified>
        <d:getcontenttype>text/plain</d:getcontenttype>
        <nc:version-label>перед правкой</nc:version-label>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/remote.php/dav/versions/art/versions/312/1756982400</d:href>
    <d:propstat>
      <d:prop>
        <d:getcontentlength>1024</d:getcontentlength>
        <d:getcontenttype>text/plain</d:getcontenttype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

/// Канал обновлений: две выпущенные версии и черновик без установщика.
const _appcastXml = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Nexus Nimbus</title>
    <item>
      <title>Nexus Nimbus 0.3.0</title>
      <sparkle:version>0.3.0</sparkle:version>
    </item>
    <item>
      <title>Nexus Nimbus 0.1.0</title>
      <pubDate>Sat, 05 Sep 2026 13:02:00 +0000</pubDate>
      <sparkle:version>0.1.0</sparkle:version>
      <description><![CDATA[
        <ul><li>Кавычки &#171;ёлочки&#187; и амперсанд &amp;</li></ul>
      ]]></description>
      <enclosure
        url="https://example.invalid/v0.1.0/NexusNimbus-Setup-0.1.0.exe"
        sparkle:version="0.1.0"
        sparkle:os="windows"
        length="23000000"
        type="application/octet-stream" />
    </item>
    <item>
      <title>Nexus Nimbus 0.2.0</title>
      <pubDate>Sat, 05 Sep 2026 18:40:00 +0000</pubDate>
      <sparkle:version>0.2.0</sparkle:version>
      <description><![CDATA[
        <style>li{margin:5px 0;}</style>
        <ul>
          <li>Корзина сервера</li>
          <li>Папка хранилища</li>
        </ul>
      ]]></description>
      <enclosure
        url="https://example.invalid/v0.2.0/NexusNimbus-Setup-0.2.0.exe"
        sparkle:version="0.2.0"
        sparkle:os="windows"
        length="24000000"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>''';
