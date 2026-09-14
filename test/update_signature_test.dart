import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_nimbus/services/update_signature.dart';

void main() {
  group('подпись установщика', () {
    // Подписано закрытым ключом проекта ровно так, как sign_update.ps1
    // подписывает установщики:
    //   openssl dgst -sha1 -binary < msg | openssl dgst -sha1 -sign dsa_priv.pem
    const message = 'Nexus Nimbus: test message for DSA verification\n';
    const signature =
        'MDsCGy+IS2bQqgIp/7uJbBebg40/khGuxS+pNc62hwIcBLm2942I/MrDxWJxUS3BWcNuMdCtpvcMd8CuDQ==';

    test('верная подпись принимается', () {
      final digest = sha1.convert(utf8.encode(message));
      expect(digest.toString(), '3aebd96f49f3935daf4b2df9570f4c60b083ab47');
      expect(
        UpdateSignature.verify(fileSha1: digest, signatureBase64: signature),
        isTrue,
      );
    });

    test('подмена файла ловится', () {
      final digest = sha1.convert(utf8.encode('$message '));
      expect(
        UpdateSignature.verify(fileSha1: digest, signatureBase64: signature),
        isFalse,
      );
    });

    test('подмена подписи ловится', () {
      final digest = sha1.convert(utf8.encode(message));
      final broken = signature.replaceRange(20, 21, signature[20] == 'A' ? 'B' : 'A');
      expect(
        UpdateSignature.verify(fileSha1: digest, signatureBase64: broken),
        isFalse,
      );
    });

    test('мусор вместо подписи — просто «нет», без исключения', () {
      final digest = sha1.convert(utf8.encode(message));
      for (final junk in ['', 'не base64', 'AAAA', 'MDsCGw==']) {
        expect(
          UpdateSignature.verify(fileSha1: digest, signatureBase64: junk),
          isFalse,
          reason: junk,
        );
      }
    });

    test('чужой ключ не принимает подпись', () {
      final digest = sha1.convert(utf8.encode(message));
      // Тот же ключ, но с испорченным y — как если бы подпись сверяли не
      // тем pem.
      final lines = UpdateSignature.publicKeyPem.trim().split('\n');
      final i = lines.length - 3;
      lines[i] = lines[i].replaceRange(0, 1, lines[i][0] == 'a' ? 'b' : 'a');
      expect(
        UpdateSignature.verify(
          fileSha1: digest,
          signatureBase64: signature,
          publicKeyPem: lines.join('\n'),
        ),
        isFalse,
      );
    });
  });
}
