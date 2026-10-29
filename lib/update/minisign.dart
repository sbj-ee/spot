// minisign signature verification (https://jedisct1.github.io/minisign/).
// Accepts the default pre-hashed "ED" form (BLAKE2b-512, then Ed25519) and
// the legacy "Ed" form, and always checks the trusted comment's global
// signature. Mirrors zwriter's Minisign.cpp.
import 'dart:convert';

import 'blake2b.dart';
import 'ed25519.dart';

/// Public half of the release key (key ID DBC46B23C3AF0EF3), the same key
/// zwriter and zedit releases are signed with. The matching secret key lives
/// only in the repo's MINISIGN_SECRET_KEY Actions secret.
const String kUpdateSigningPublicKey =
    'RWTzDq/DI2vE2xMeF01QWTxP2lwwlxGL9M1UxQE4EFV5kVmTF84wwyi2';

List<int>? _b64(String s) {
  try {
    return base64.decode(s.trim());
  } on FormatException {
    return null;
  }
}

/// Returns null when [signatureFile] is a valid minisign signature of [data]
/// by [publicKey] (base64, as in a minisign.pub file), else a reason.
String? minisignVerify(String publicKey, List<int> data, String signatureFile) {
  final pk = _b64(publicKey);
  if (pk == null || pk.length != 42 || pk[0] != 0x45 || pk[1] != 0x64) {
    return 'bad public key';
  }
  final lines = const LineSplitter().convert(signatureFile);
  if (lines.length < 4 || !lines[0].startsWith('untrusted comment:')) {
    return 'malformed signature file';
  }
  const tcPrefix = 'trusted comment: ';
  if (!lines[2].startsWith(tcPrefix)) return 'missing trusted comment';
  final sig = _b64(lines[1]);
  final global = _b64(lines[3]);
  if (sig == null ||
      sig.length != 74 ||
      global == null ||
      global.length != 64) {
    return 'malformed signature';
  }
  for (var i = 0; i < 8; i++) {
    if (sig[2 + i] != pk[2 + i]) return 'signed with a different key';
  }
  final key = pk.sublist(10);
  final List<int> message;
  if (sig[0] == 0x45 && sig[1] == 0x44) {
    message = blake2b512(data); // "ED"
  } else if (sig[0] == 0x45 && sig[1] == 0x64) {
    message = data; // "Ed"
  } else {
    return 'unknown signature algorithm';
  }
  final sigBytes = sig.sublist(10);
  if (!ed25519Verify(key, message, sigBytes)) return 'signature does not match';
  final trusted = utf8.encode(lines[2].substring(tcPrefix.length));
  if (!ed25519Verify(key, [...sigBytes, ...trusted], global)) {
    return 'trusted comment signature does not match';
  }
  return null;
}
