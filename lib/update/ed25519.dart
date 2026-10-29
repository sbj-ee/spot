// Ed25519 signature verification (RFC 8032, section 5.1.7), written with
// BigInt. It only checks a couple of release signatures, so clarity wins over
// speed. Verification only; Spot never signs anything.
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha512;

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _l =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');
final BigInt _d = (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;
final BigInt _d2 = (_d * BigInt.two) % _p;
final BigInt _sqrtM1 = BigInt.two.modPow(
  (_p - BigInt.one) ~/ BigInt.from(4),
  _p,
);

BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);

class _Pt {
  const _Pt(this.x, this.y, this.z, this.t);
  final BigInt x, y, z, t;
}

_Pt _add(_Pt p, _Pt q) {
  final a = ((p.y - p.x) * (q.y - q.x)) % _p;
  final b = ((p.y + p.x) * (q.y + q.x)) % _p;
  final c = (p.t * _d2 * q.t) % _p;
  final d = (p.z * BigInt.two * q.z) % _p;
  final e = b - a, f = d - c, g = d + c, h = b + a;
  return _Pt((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
}

_Pt _mul(BigInt s, _Pt p) {
  var q = _Pt(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);
  while (s > BigInt.zero) {
    if (s.isOdd) q = _add(q, p);
    p = _add(p, p);
    s >>= 1;
  }
  return q;
}

BigInt _leInt(List<int> b) {
  var v = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(b[i]);
  }
  return v;
}

Uint8List _encode(_Pt p) {
  final zi = _inv(p.z);
  final x = (p.x * zi) % _p;
  var y = (p.y * zi) % _p;
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = (y & BigInt.from(0xff)).toInt();
    y >>= 8;
  }
  if (x.isOdd) out[31] |= 0x80;
  return out;
}

_Pt? _decode(List<int> s) {
  if (s.length != 32) return null;
  final b = Uint8List.fromList(s);
  final sign = b[31] >> 7;
  b[31] &= 0x7f;
  final y = _leInt(b);
  if (y >= _p) return null;
  final y2 = (y * y) % _p;
  final x2 = ((y2 - BigInt.one) * _inv((_d * y2 + BigInt.one) % _p)) % _p;
  if (x2 == BigInt.zero) {
    if (sign == 1) return null;
    return _Pt(BigInt.zero, y, BigInt.one, BigInt.zero);
  }
  var x = x2.modPow((_p + BigInt.from(3)) ~/ BigInt.from(8), _p);
  if ((x * x - x2) % _p != BigInt.zero) x = (x * _sqrtM1) % _p;
  if ((x * x - x2) % _p != BigInt.zero) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _p - x;
  return _Pt(x, y, BigInt.one, (x * y) % _p);
}

final _Pt _base = () {
  final y = (BigInt.from(4) * _inv(BigInt.from(5))) % _p;
  final enc = Uint8List(32);
  var v = y;
  for (var i = 0; i < 32; i++) {
    enc[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return _decode(enc)!;
}();

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var r = 0;
  for (var i = 0; i < a.length; i++) {
    r |= a[i] ^ b[i];
  }
  return r == 0;
}

/// True when [signature] (64 bytes) is a valid Ed25519 signature of
/// [message] by [publicKey] (32 bytes).
bool ed25519Verify(
  List<int> publicKey,
  List<int> message,
  List<int> signature,
) {
  if (publicKey.length != 32 || signature.length != 64) return false;
  final a = _decode(publicKey);
  if (a == null) return false;
  final r = signature.sublist(0, 32);
  final s = _leInt(signature.sublist(32));
  if (s >= _l) return false;
  final h = _leInt(sha512.convert([...r, ...publicKey, ...message]).bytes) % _l;
  final negA = _Pt((_p - a.x) % _p, a.y, a.z, (_p - a.t) % _p);
  final check = _add(_mul(s, _base), _mul(h, negA));
  return _eq(_encode(check), r);
}
