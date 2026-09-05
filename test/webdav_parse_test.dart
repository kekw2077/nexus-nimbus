import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_nimbus/core/format.dart';
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

  group('форматирование', () {
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
  });
}
