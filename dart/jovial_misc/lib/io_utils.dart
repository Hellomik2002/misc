/// Miscellaneous I/O utilities.

library io_utils;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:async/async.dart'; // Only for Cipher*Stream
import 'package:pointycastle/export.dart'; // Only for Cipher*Stream

class EOFException implements IOException {
  final String message;

  const EOFException(this.message);

  @override
  String toString() {
    return 'EOFException: $message';
  }
}

/// `DataInputStream` is a coroutines-style wrapper around a
/// `Stream<List<int>>`, like you get from a socket or a file in Dart.
/// This lets you asynchronously read a stream using an API much like
/// `java.io.DataInputStream`.
///
/// Note that this class does not read all of the data into a buffer first,
/// so it is very space-efficient.  It does, however, use asynchrony at a
/// fairly granular level.  This might have performance implications, depending
/// on how efficient async/await are in current Dart implementations.  As
/// of this writing (Jan. 2020), I have not measured.
///
/// See also [ByteBufferDataInputStream].
class DataInputStream {
  // This class iterates through the provided Stream<List<int>> directly,
  // and buffers by hanging onto a Uint8List  until it's been completely
  // read.  I suppose I could have based this off of quiver's
  // StreamBuffer class, but as the great Japanese philosopher
  // Gudetama famously said, "meh."   (⊃◜⌓◝⊂)
  final StreamIterator<List<int>> _source;
  Uint8List _curr;
  int _pos;
  static const _utf8Decoder = Utf8Decoder(allowMalformed: true);

  /// The current endian setting, either [Endian.big] or [Endian.little].
  /// This is used for converting numeric types.
  Endian endian;

  DataInputStream(Stream<List<int>> source, [this.endian = Endian.big])
      : _source = StreamIterator<List<int>>(source);

  /// Returns the number of bytes that can be read from the internal buffer.
  ///  If we're at EOF, returns zero, otherwise, returns a non-zero positive
  ///  integer.  If the buffer is currently exhausted, this method will wait
  ///  for the next block of data to come in.
  Future<int> get bytesAvailable async {
    if (await isEOF()) {
      return 0;
    }
    return _curr.length - _pos;
  }

  /// Check if we're at end of file.
  Future<bool> isEOF() async {
    while (_curr == null || _pos == _curr.length) {
      final ok = await _source.moveNext();
      if (!ok) {
        return true;
      }
      if (_source.current is Uint8List) {
        _curr = _source.current;
      } else {
        _curr = Uint8List.fromList(_source.current);
        // I don't think this ever happens when reading from a file,
        // but better safe than sorry.
      }
      _pos = 0;
      // Loop around again, in case we got an empty buffer.
    }
    return false;
  }

  /// Make sure that at least one byte is in the buffer.
  Future<void> _ensureNext() async {
    if (await isEOF()) {
      throw EOFException('Unexpected EOF');
    }
    // isEOF() sets up _curr and _pos as a side effect.
  }

  /// Returns a new, mutable [Uint8List] containing the desired number
  /// of bytes.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<Uint8List> readBytes(int num) async {
    if (num == 0) {
      return Uint8List(0);
    }
    await _ensureNext();
    if (_pos + num <= _curr.length) {
      final result = _curr.sublist(_pos, _pos + num);
      _pos += num;
      return result;
    } else {
      final len = _curr.length - _pos;
      assert(len > 0 && len < num);
      final result = Uint8List(num);
      final buf = await readBytes(len);
      result.setRange(0, len, buf);
      final buf2 = await readBytes(num - len);
      result.setRange(len, num, buf2);
      return result;
    }
  }

  /// Returns a potentially immutable [Uint8List] containing the desired number
  /// of bytes.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<Uint8List> readBytesImmutable(int num) async {
    if (num == 0) {
      return Uint8List(0);
    }
    await _ensureNext();
    if (_pos == 0 && num == _curr.length) {
      _pos = _curr.length;
      return _curr;
    } else if (_pos + num <= _curr.length) {
      final result = _curr.sublist(_pos, _pos + num);
      _pos += num;
      return result;
    } else {
      final len = _curr.length - _pos;
      assert(len > 0 && len < num);
      final result = Uint8List(num);
      var buf = await readBytes(len);
      result.setRange(0, len, buf);
      buf = await readBytes(num - len);
      result.setRange(len, num, buf);
      return result;
    }
  }

  /// Reads and returns a 4-byte signed integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<int> readInt() async {
    await _ensureNext();
    if (_curr.length - _pos < 4) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(4)).buffer).getInt32(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getInt32(_pos, endian);
      _pos += 4;
      return result;
    }
  }

  /// Reads and returns a 4-byte unsigned integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<int> readUnsignedInt() async {
    await _ensureNext();
    if (_curr.length - _pos < 4) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(4)).buffer).getUint32(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getUint32(_pos, endian);
      _pos += 4;
      return result;
    }
  }

  /// Reads and returns a 2-byte unsigned integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<int> readUnsignedShort() async {
    await _ensureNext();
    if (_curr.length - _pos < 2) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(2)).buffer).getUint16(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getUint16(_pos, endian);
      _pos += 2;
      return result;
    }
  }

  /// Reads and returns a 2-byte signed integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<int> readShort() async {
    await _ensureNext();
    if (_curr.length - _pos < 2) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(2)).buffer).getInt16(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getInt16(_pos, endian);
      _pos += 2;
      return result;
    }
  }

  /// Reads and returns an unsigned byte.
  ///
  /// Throws [EOFException] if EOF is reached before the needed byte is read.
  Future<int> readUnisgnedByte() async {
    await _ensureNext();
    return _curr[_pos++];
  }

  /// Reads and returns a signed byte.  No sign extension is done.
  ///
  /// Throws EOFException if EOF is reached before the needed byte is read.
  Future<int> readByte() async {
    await _ensureNext();
    final b = _curr[_pos++];
    if (b & 0x80 != 0) {
      return b - 0x100;
    } else {
      return b;
    }
  }

  /// Reads and returns an 8-byte integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<int> readLong() async {
    await _ensureNext();
    if (_curr.length - _pos < 8) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(8)).buffer).getInt64(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getInt64(_pos, endian);
      _pos += 8;
      return result;
    }
  }

  /// Reads and returns an 8-byte integer, converted to
  /// a Dart int according to the semantics of [ByteData.getUint64]
  /// using the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<int> readUnsignedLong() async {
    await _ensureNext();
    if (_curr.length - _pos < 8) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(8)).buffer).getUint64(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getUint64(_pos, endian);
      _pos += 8;
      return result;
    }
  }

  /// Reads and returns a 4-byte float, using the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<double> readFloat() async {
    await _ensureNext();
    if (_curr.length - _pos < 4) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(4)).buffer).getFloat32(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getFloat32(_pos, endian);
      _pos += 4;
      return result;
    }
  }

  /// Reads and returns an 8-byte double, using the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<double> readDouble() async {
    await _ensureNext();
    if (_curr.length - _pos < 8) {
      // If we're on a buffer boundary
      // Keep it simple
      return ByteData.view((await readBytes(8)).buffer).getFloat64(0, endian);
    } else {
      var result = ByteData.view(_curr.buffer).getFloat64(_pos, endian);
      _pos += 8;
      return result;
    }
  }

  /// Reads a string encoded in UTF8.  This method first reads a 2 byte
  /// unsigned integer decoded with the current [endian] setting,
  /// giving the number of UTF8 bytes to read.  It then reads
  /// those bytes, and converts them to a string using Dart's UTF8 conversion.
  /// This may be incompatible with `java.io.DataOutputStream`
  /// for a string that contains nulls.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Future<String> readUTF8() async {
    final len = await readUnsignedShort();
    final bytes = await readBytesImmutable(len);
    return _utf8Decoder.convert(bytes);
  }

  /// Reads a byte, and returns false if it is 0, true otherwise.
  ///
  /// Throws [EOFException] if EOF is reached before the needed byte is read.
  Future<bool> readBoolean() async {
    await _ensureNext();
    return _curr[_pos++] != 0;
  }

  /// Returns the next unsigned byte, or -1 on EOF
  Future<int> read() async {
    if (await isEOF()) {
      return -1;
    } else {
      return _curr[_pos++];
    }
  }

  /// Test out the buffer logic by returning 3 bytes at a time.  The stream
  /// obtained from this method can be fed into another DataInputStream.
  Stream<Uint8List> debugStream() async* {
    while (true) {
      final a = await read();
      if (a == -1) {
        break; // EOF, so bail
      }
      final b = await read();
      if (b == -1) {
        yield Uint8List.fromList([a]);
        break;
      }
      final c = await read();
      if (c == -1) {
        yield Uint8List.fromList([a, b]);
        break;
      }
      yield Uint8List.fromList([a, b, c]);
    }
  }

  /// Give a stream containing our as-yet-unread bytes.
  Stream<Uint8List> remaining() async* {
    if (_curr != null && _pos < _curr.length) {
      yield await readBytes(_curr.length - _pos);
    }
    while (true) {
      if (!await _source.moveNext()) {
        break;
      }
      if (_source.current is Uint8List) {
        yield _source.current;
      } else {
        yield Uint8List.fromList(_source.current);
        // I don't think this ever happens when reading from a file,
        // but better safe than sorry.
      }
    }
    close();
  }

  /// Cancel our underling stream.
  void close() async {
    return _source.cancel(); // That's a future
  }
}

/// [ByteBufferDataInputStream] is a wrapper around a [ByteBuffer]
/// instance.  This lets you synchronously read typed binary data from a byte
/// array, much like `java.io.DataInputStream` over a `ByteArrayInputStream`.
///
/// See also [DataInputStream]
class ByteBufferDataInputStream {
  final Uint8List _source;
  final ByteData _asByteData;
  int _pos = 0;
  static const _utf8Decoder = Utf8Decoder(allowMalformed: true);

  /// The current endian setting, either [Endian.big] or [Endian.little].
  /// This is used for converting numeric types.
  Endian endian;

  ByteBufferDataInputStream(Uint8List source, [this.endian = Endian.big])
      : _source = source,
        _asByteData = source.buffer.asByteData();

  /// Returns the number of bytes that can be read from the internal buffer.
  ///  If we're at EOF, returns zero, otherwise, returns a non-zero positive
  ///  integer.
  int get bytesAvailable => _source.lengthInBytes - _pos;

  /// Check if we're at end of file.
  bool isEOF() => _source.lengthInBytes <= _pos;

  /// Returns a new, mutable [Uint8List] containing the desired number
  /// of bytes.
  Uint8List readBytes(int num) {
    return readBytesImmutable(num);
  }

  /// Returns a potentially immutable [Uint8List] containing the desired number
  /// of bytes.  If the returned list is mutable, changing it might write
  /// through our internal buffer.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  Uint8List readBytesImmutable(int num) {
    if (_pos + num > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _source.sublist(_pos, _pos + num);
      _pos += num;
      return result;
    }
  }

  /// Reads and returns a 4-byte signed integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  int readInt() {
    if (_pos + 4 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getInt32(_pos, endian);
      _pos += 4;
      return result;
    }
  }

  /// Reads and returns a 4-byte unsigned integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  int readUnsignedInt() {
    if (_pos + 4 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getUint32(_pos, endian);
      _pos += 4;
      return result;
    }
  }

  /// Reads and returns a 2-byte unsigned integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  int readUnsignedShort() {
    if (_pos + 2 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getUint16(_pos, endian);
      _pos += 2;
      return result;
    }
  }

  /// Reads and returns a 2-byte signed integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  int readShort() {
    if (_pos + 2 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getInt16(_pos, endian);
      _pos += 2;
      return result;
    }
  }

  /// Reads and returns an unsigned byte.
  ///
  /// Throws [EOFException] if EOF is reached before the needed byte is read.
  int readUnsignedByte() {
    if (_pos + 1 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getUint8(_pos);
      _pos += 1;
      return result;
    }
  }

  /// Reads and returns a signed byte.  No sign extension is done.
  ///
  /// Throws [EOFException] if EOF is reached before the needed byte is read.
  int readByte() {
    if (_pos + 1 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final b = _asByteData.getInt8(_pos);
      _pos += 1;
      if (b & 0x80 != 0) {
        return b - 0x100;
      } else {
        return b;
      }
    }
  }

  /// Reads and returns an 8-byte signed integer
  /// decoded with the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  int readLong() {
    if (_pos + 8 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getInt64(_pos, endian);
      _pos += 8;
      return result;
    }
  }

  /// Reads and returns an 8-byte unsigned integer, converted to
  /// a Dart int according to the semantics of [ByteData.getUint64]
  /// using the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  int readUnsignedLong() {
    if (_pos + 8 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getUint64(_pos, endian);
      _pos += 8;
      return result;
    }
  }

  /// Reads and returns a 4-byte float, using the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  double readFloat() {
    if (_pos + 4 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getFloat32(_pos, endian);
      _pos += 4;
      return result;
    }
  }

  /// Reads and returns an 8-byte double, using the current [endian] setting.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  double readDouble() {
    if (_pos + 8 > _source.lengthInBytes) {
      throw EOFException('Attempt to read beyond end of input');
    } else {
      final result = _asByteData.getFloat64(_pos, endian);
      _pos += 8;
      return result;
    }
  }

  /// Reads a string encoded in UTF8.  This method first reads a 2 byte
  /// unsigned integer decoded with the current [endian] setting,
  /// giving the number of UTF8 bytes to read.  It then reads
  /// those bytes, and converts them to a string using Dart's UTF8 conversion.
  /// This may be incompatible with `java.io.DataOutputStream` for a string
  /// that contains nulls.
  ///
  /// Throws [EOFException] if EOF is reached before the needed bytes are read.
  String readUTF8() {
    final len = readUnsignedShort();
    final bytes = readBytesImmutable(len);
    return _utf8Decoder.convert(bytes);
  }

  /// Reads a byte, and returns `false` if it is 0, `true` otherwise.
  ///
  /// Throws EOFException if EOF is reached before the needed byte is read.
  bool readBoolean() {
    return readUnsignedByte() != 0;
  }

  /// Returns the next unsigned byte, or -1 on EOF
  int read() {
    if (isEOF()) {
      return -1;
    } else {
      return readUnsignedByte();
    }
  }

  /// Render this stream un-readalbe.  This positions the stream to EOF.
  void close() {
    _pos = _source.lengthInBytes;
  }
}

/// An adapter over a `Sink<List<int>>` for writing to a stream.  This class
/// presents an API based on Java's `java.io.DataOutputStream`.
///
/// DataOutputSink does no buffering.
class DataOutputSink {
  final Sink<List<int>> _dest;

  /// The current endian setting, either [Endian.big] or [Endian.little].
  /// This is used for converting numeric types.
  Endian endian;

  DataOutputSink(this._dest, [this.endian = Endian.big]);

  /// Write the low 8 bits of the given integer as a single byte.
  void writeByte(int b) {
    _dest.add(Uint8List.fromList([b & 0xff]));
  }

  /// Write the given bytes.  A [Uint8List] is the recommended subtype
  /// of `List<int>`.
  void writeBytes(List<int> bytes) {
    if (bytes is Uint8List) {
      _dest.add(bytes);
    } else {
      _dest.add(Uint8List.fromList(bytes));
    }
  }

  /// Writes a byte containg `0` if `v` is `false`, and `1` if it is `true`.
  void writeBoolean(bool v) {
    writeByte(v ? 1 : 0);
  }

  /// Writes a 2 byte signed short using the current [endian] format.
  void writeShort(int v) {
    final d = ByteData(2)..setInt16(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Writes a 2 byte unsigned short using the current [endian] format.
  void writeUnsignedShort(int v) {
    final d = ByteData(2)..setUint16(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Writes a 4 byte int using the current [endian] format.
  void writeInt(int v) {
    final d = ByteData(4)..setInt32(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Writes a 4 byte unsigned int using the current [endian] format.
  void writeUnsignedInt(int v) {
    final d = ByteData(4)..setUint32(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Writes an 8 byte long int using the current [endian] format.
  void writeLong(int v) {
    final d = ByteData(8)..setInt64(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Writes an unsigned 8 byte long using the current [endian] format.
  /// Converts a Dart
  /// `int` according to the semantics of [ByteData.setUint64`.
  void writeUnsignedLong(int v) {
    final d = ByteData(8)..setUint64(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Writes a four-byte float using the current [endian] format.
  void writeFloat(double v) {
    final d = ByteData(4)..setFloat32(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Writes an eight-byte double using the current [endian] format.
  void writeDouble(double v) {
    final d = ByteData(8)..setFloat64(0, v, endian);
    _dest.add(d.buffer.asUint8List());
  }

  /// Write the given string as an unsigned short giving the byte length,
  /// followed by that many bytes containing the UTF8 encoding.
  /// The short is written using the current [endian] format.
  /// This should be compatable with
  /// Java's `DataOutputStream.writeUTF8()`, as long as the string contains no
  /// nulls and no UTF formats beyond the 1, 2 and 3 byte formats.  See
  /// https://docs.oracle.com/en/java/javase/11/docs/api/java.base/java/io/DataInput.html#modified-utf-8
  ///
  /// Throws an ArgumentError if the encoded string length doesn't fit
  /// in an unsigned short.
  void writeUTF8(String s) {
    final utf8 = (const Utf8Encoder()).convert(s);
    if (utf8.length > 0xffffffff) {
      throw ArgumentError(
          'Byte length ${utf8.length} exceeds maximum of ${0xffffffff}');
    }
    writeUnsignedShort(utf8.length);
    _dest.add(utf8);
  }

  void close() {
    _dest.close();
  }
}

/// A wrapper around a [DataInputStream] that decrypts using
/// a Pointycastle [BlockCipher], resulting in a `Stream<List<int>>`.
class DecryptingStream extends DelegatingStream<Uint8List> {
  DecryptingStream(BlockCipher cipher, Stream<List<int>> input, Padding padding)
      : this.fromDataInputStream(cipher, DataInputStream(input), padding);

  DecryptingStream.fromDataInputStream(
      BlockCipher cipher, DataInputStream input, Padding padding)
      : super(_generate(cipher, input, padding));

  static Stream<Uint8List> _generate(
      BlockCipher cipher, DataInputStream input, Padding padding) async* {
    final bs = cipher.blockSize;
    while (true) {
      final len = max(((await input.bytesAvailable) ~/ bs) * bs, bs);
      // A well-formed encrypted stream will have at least one block,
      // due to padding, and its length will be evenly divisible by the
      // block size.  A well-formed encrypted stream will therefore never
      // generate an EOF in the following line.
      final cipherText = await input.readBytesImmutable(len);
      final plainText = Uint8List(len);
      for (var i = 0; i < len; i += bs) {
        cipher.processBlock(cipherText, i, plainText, i);
      }
      if (await input.isEOF()) {
        final padBytes = padding.padCount(plainText.sublist(len - bs, len));
        if (padBytes < plainText.length) {
          // If not all padding
          yield plainText.sublist(0, plainText.length - padBytes);
        }
        break;
      } else {
        yield plainText;
      }
    }
  }
}

/// A wrapper around a `Sink<List<int>>` that encrypts data using
/// a Pointycastle [BlockCipher].  This sink needs to buffer to build
/// up blocks that can be encrypted, so it's essential that [close()]
/// be called.
class EncryptingSink implements Sink<List<int>> {
  final BlockCipher _cipher;
  final Sink<List<int>> _dest;
  final Padding _padding;
  final Uint8List _lastPlaintext;
  int _lastPlaintextPos = 0;
  bool _closed = false;

  EncryptingSink(this._cipher, this._dest, this._padding)
      : _lastPlaintext = Uint8List(_cipher.blockSize);

  @override
  void close() {
    assert(!_closed);
    final bs = _cipher.blockSize;
    if (_lastPlaintextPos > 0) {
      for (var i = _lastPlaintextPos; i < bs; i++) {
        _lastPlaintext[i] = 0;
      }
    }
    _padding.addPadding(_lastPlaintext, _lastPlaintextPos);
    _emit(_lastPlaintext, 0, _lastPlaintext.length);
    _closed = true;
    _dest.close();
  }

  @override
  void add(List<int> data) {
    final bs = _cipher.blockSize;

    // Deal with any pending bytes
    var fromPos = 0;
    {
      final total = _lastPlaintextPos + data.length;
      if (total < bs) {
        _lastPlaintext.setRange(_lastPlaintextPos, total, data);
        _lastPlaintextPos = total;
        return;
      }
      _lastPlaintext.setRange(_lastPlaintextPos, bs, data);
      _emit(_lastPlaintext, 0, bs);
      fromPos = bs - _lastPlaintextPos;
    }

    if (fromPos == data.length) {
      _lastPlaintextPos = 0;
      return; // No more to do
    }

    final toEmit = ((data.length - fromPos) ~/ bs) * bs;
    _emit(data, fromPos, toEmit);
    fromPos += toEmit;

    _lastPlaintextPos = data.length - fromPos;
    if (_lastPlaintextPos > 0) {
      _lastPlaintext.setRange(0, _lastPlaintextPos,
          data.getRange(fromPos, fromPos + _lastPlaintextPos));
    } else {
      // Keep the last block of plaintext around, in case we need it
      // to generate the padding.  See Padding.addPadding() in Pointycastle.
      _lastPlaintext.setRange(
          0, bs, data.getRange(data.length - bs, data.length));
    }
  }

  void _emit(List<int> block, int offset, int len) {
    final bs = _cipher.blockSize;
    assert(len % bs == 0);
    if (len == 0) {
      return;
    }
    final block8 = (block is Uint8List) ? block : Uint8List.fromList(block);
    final out = Uint8List(len);
    for (var i = 0; i < out.length; i += bs) {
      _cipher.processBlock(block8, i + offset, out, i);
    }
    _dest.add(out);
  }
}
