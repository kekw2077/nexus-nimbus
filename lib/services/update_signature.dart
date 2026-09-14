import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Проверка подписи установщика — та же схема, что у WinSparkle, чтобы
/// ключи, `sign_update.ps1` и записи в канале остались прежними:
///
///     openssl dgst -sha1 -binary < file | openssl dgst -sha1 -sign key
///
/// То есть DSA поверх SHA-1 от SHA-1 файла. DSA — это несколько возведений
/// в степень по модулю, и `BigInt` в Dart с ними справляется сам; сторонняя
/// библиотека тут не нужна, а WinSparkle — тем более.
///
/// Открытый ключ зашит прямо сюда: раньше он лежал в ресурсах exe для
/// WinSparkle, теперь читает его только этот код. Парный закрытый ключ —
/// `dsa_priv.pem` в корне проекта, в git не попадает.
class UpdateSignature {
  const UpdateSignature._();

  /// Содержимое dsa_pub.pem. Менять только вместе с закрытым ключом — и
  /// помнить, что установленные копии со старым ключом новую подпись не
  /// примут (dist/README.md, «Ключи»).
  static const publicKeyPem = '''
-----BEGIN PUBLIC KEY-----
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
3HCe5Xm8MwGQxHgyBi97VhzO8AFEI4Q=
-----END PUBLIC KEY-----
''';

  /// Верна ли подпись из канала (`sparkle:dsaSignature`, base64) для файла
  /// с таким SHA-1. Любая кривизна — не тот формат, не тот ключ, обрезанная
  /// строка — это просто «нет», без исключений: дальше файл не запустится.
  static bool verify({
    required Digest fileSha1,
    required String signatureBase64,
    String publicKeyPem = publicKeyPem,
  }) {
    try {
      final key = _DsaPublicKey.parse(publicKeyPem);
      final (r, s) = _parseSignature(base64.decode(signatureBase64.trim()));
      // Второй SHA-1 — от байтов первого: так делает `openssl dgst -sign`
      // поверх уже посчитанного `-binary`-дайджеста.
      final z = _bigInt(Uint8List.fromList(sha1.convert(fileSha1.bytes).bytes));
      return key.verify(z, r, s);
    } catch (_) {
      return false;
    }
  }

  /// Подпись в DER: SEQUENCE { INTEGER r, INTEGER s }.
  static (BigInt, BigInt) _parseSignature(List<int> der) {
    final seq = _Der(Uint8List.fromList(der)).sequence();
    return (seq.integer(), seq.integer());
  }

  static BigInt _bigInt(Uint8List bytes) {
    var v = BigInt.zero;
    for (final b in bytes) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }
}

class _DsaPublicKey {
  const _DsaPublicKey(this.p, this.q, this.g, this.y);

  final BigInt p, q, g, y;

  /// SubjectPublicKeyInfo из PEM:
  /// SEQUENCE { SEQUENCE { OID dsa, SEQUENCE { p, q, g } }, BIT STRING { y } }.
  static _DsaPublicKey parse(String pem) {
    final body = pem
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    final spki = _Der(Uint8List.fromList(base64.decode(body))).sequence();

    final algorithm = spki.sequence();
    final oid = algorithm.next(0x06);
    if (!_listEquals(oid, _dsaOid)) {
      throw const FormatException('Ключ не DSA');
    }
    final params = algorithm.sequence();
    final p = params.integer();
    final q = params.integer();
    final g = params.integer();

    final bits = spki.next(0x03);
    // Первый байт BIT STRING — число неиспользуемых битов, у целого ключа 0.
    final y = _Der(Uint8List.sublistView(bits, 1)).integer();
    return _DsaPublicKey(p, q, g, y);
  }

  // 1.2.840.10040.4.1
  static final _dsaOid = Uint8List.fromList([0x2a, 0x86, 0x48, 0xce, 0x38, 0x04, 0x01]);

  /// FIPS 186-4, 4.7. [z] — хеш как число; если он длиннее q, берутся
  /// старшие биты, как делает OpenSSL. У нас SHA-1 короче q, так что z идёт
  /// целиком.
  bool verify(BigInt z, BigInt r, BigInt s) {
    if (r <= BigInt.zero || r >= q || s <= BigInt.zero || s >= q) return false;

    final zBits = z.bitLength;
    final qBits = q.bitLength;
    final hash = zBits > qBits ? z >> (zBits - qBits) : z;

    final w = s.modInverse(q);
    final u1 = (hash * w) % q;
    final u2 = (r * w) % q;
    final v = ((g.modPow(u1, p) * y.modPow(u2, p)) % p) % q;
    return v == r;
  }

  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Ровно столько DER, сколько нужно для ключа и подписи: длина в одном
/// или нескольких байтах, вложенные SEQUENCE и положительные INTEGER.
class _Der {
  _Der(this.bytes);

  final Uint8List bytes;
  int _pos = 0;

  Uint8List next(int tag) {
    if (_pos >= bytes.length) throw const FormatException('DER оборван');
    final actual = bytes[_pos++];
    if (actual != tag) {
      throw FormatException('DER: ждали тег $tag, пришёл $actual');
    }
    var len = bytes[_pos++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | bytes[_pos++];
      }
    }
    if (_pos + len > bytes.length) throw const FormatException('DER оборван');
    final out = Uint8List.sublistView(bytes, _pos, _pos + len);
    _pos += len;
    return out;
  }

  _Der sequence() => _Der(next(0x30));

  BigInt integer() {
    final raw = next(0x02);
    if (raw.isNotEmpty && raw[0] & 0x80 != 0) {
      throw const FormatException('DER: отрицательное число в ключе');
    }
    return UpdateSignature._bigInt(raw);
  }
}
