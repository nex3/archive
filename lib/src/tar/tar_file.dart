import 'dart:math' as math;

import 'package:typed_data/typed_data.dart';

import '../util/archive_exception.dart';
import '../util/input_stream.dart';

/*  File Header (512 bytes)
 *  Offst Size Field
 *      Pre-POSIX Header
 *  0     100  File name
 *  100   8    File mode
 *  108   8    Owner's numeric user ID
 *  116   8    Group's numeric user ID
 *  124   12   File size in bytes (octal basis)
 *  136   12   Last modification time in numeric Unix time format (octal)
 *  148   8    Checksum for header record
 *  156   1    Type flag
 *  157   100  Name of linked file
 *      UStar Format
 *  257   6    UStar indicator "ustar"
 *  263   2    UStar version "00"
 *  265   32   Owner user name
 *  297   32   Owner group name
 *  329   8    Device major number
 *  337   8    Device minor number
 *  345   155  Filename prefix
 */

class TarFile {
  static const String TYPE_NORMAL_FILE = '0';
  static const String TYPE_HARD_LINK = '1';
  static const String TYPE_SYMBOLIC_LINK = '2';
  static const String TYPE_CHAR_SPEC = '3';
  static const String TYPE_BLOCK_SPEC = '4';
  static const String TYPE_DIRECTORY = '5';
  static const String TYPE_FIFO = '6';
  static const String TYPE_CONT_FILE = '7';
  // global extended header with meta data (POSIX.1-2001)
  static const String TYPE_G_EX_HEADER = 'g';
  static const String TYPE_G_EX_HEADER2 = 'G';
  // extended header with meta data for the next file in the archive
  // (POSIX.1-2001)
  static const String TYPE_EX_HEADER = 'x';
  static const String TYPE_EX_HEADER2 = 'X';

  // Pre-POSIX Format
  String filename; // 100 bytes
  int mode = 644; // 8 bytes
  int ownerId = 0; // 8 bytes
  int groupId = 0; // 8 bytes
  int fileSize = 0; // 12 bytes
  int lastModTime = 0; // 12 bytes
  int checksum = 0; // 8 bytes
  String typeFlag = '0'; // 1 byte
  String nameOfLinkedFile; // 100 bytes
  // UStar Format
  String ustarIndicator = ''; // 6 bytes (ustar)
  String ustarVersion = ''; // 2 bytes (00)
  String ownerUserName = ''; // 32 bytes
  String ownerGroupName = ''; // 32 bytes
  int deviceMajorNumber = 0; // 8 bytes
  int deviceMinorNumber = 0; // 8 bytes
  String filenamePrefix = ''; // 155 bytes
  InputStream _rawContent;
  dynamic _content;

  TarFile();

  TarFile.read(InputStreamBase input) {
    final header = input.readBytes(512);

    // The name, linkname, magic, uname, and gname are null-terminated
    // character strings. All other fields are zero-filled octal numbers in
    // ASCII. Each numeric field of width w contains w minus 1 digits, and a
    // null.
    filename = _parseString(header, 100);
    mode = _parseInt(header, 8);
    ownerId = _parseInt(header, 8);
    groupId = _parseInt(header, 8);
    fileSize = _parseInt(header, 12);
    lastModTime = _parseInt(header, 12);
    checksum = _parseInt(header, 8);
    typeFlag = _parseString(header, 1);
    nameOfLinkedFile = _parseString(header, 100);

    ustarIndicator = _parseString(header, 6);
    if (ustarIndicator == 'ustar') {
      ustarVersion = _parseString(header, 2);
      ownerUserName = _parseString(header, 32);
      ownerGroupName = _parseString(header, 32);
      deviceMajorNumber = _parseInt(header, 8);
      deviceMinorNumber = _parseInt(header, 8);
    }

    if (filename == '././@LongLink') {
      _rawContent = input.readBytes(fileSize);
    } else {
      input.skip(fileSize);
    }

    if (isFile && fileSize > 0) {
      final remainder = fileSize % 512;
      var skiplen = 0;
      if (remainder != 0) {
        skiplen = 512 - remainder;
        input.skip(skiplen);
      }
    }
  }

  bool get isFile => typeFlag != TYPE_DIRECTORY;

  bool get isSymLink => typeFlag == TYPE_SYMBOLIC_LINK;

  InputStream get rawContent => _rawContent;

  dynamic get content {
    _content ??= _rawContent.toUint8List();
    return _content;
  }

  List<int> get contentBytes => content as List<int>;

  set content(dynamic data) => _content = data;

  int get size => _content != null
      ? _content.length as int
      : _rawContent != null
          ? _rawContent.length
          : 0;

  @override
  String toString() => '[${filename}, ${mode}, ${fileSize}]';

  void write(Uint8Buffer buffer) {
    fileSize = size;

    // The name, linkname, magic, uname, and gname are null-terminated
    // character strings. All other fields are zero-filled octal numbers in
    // ASCII. Each numeric field of width w contains w minus 1 digits, and a null.
    final headerStart = buffer.length;
    _writeString(buffer, filename, 100);
    _writeInt(buffer, mode, 8);
    _writeInt(buffer, ownerId, 8);
    _writeInt(buffer, groupId, 8);
    _writeInt(buffer, fileSize, 12);
    _writeInt(buffer, lastModTime, 12);
    _writeString(buffer, '        ', 8); // checksum placeholder
    _writeString(buffer, typeFlag, 1);

    // TAR headers are always padded with 0s to 512 bytes.
    var lengthWithHeader = headerStart + 512;
    assert(buffer.length <= lengthWithHeader);
    buffer.length = lengthWithHeader;

    // The checksum is calculated by taking the sum of the unsigned byte values
    // of the header record with the eight checksum bytes taken to be ascii
    // spaces (decimal value 32). It is stored as a six digit octal number
    // with leading zeroes followed by a NUL and then a space.

    // TODO(nweiz): Use the sum extension method when we can use null-safe
    // package versions.
    var sum = 0;
    for (var b in buffer.skip(headerStart)) {
      sum += b;
    }

    var sum_str = sum.toRadixString(8); // octal basis
    while (sum_str.length < 6) {
      sum_str = '0' + sum_str;
    }

    var checksumIndex = headerStart + 148; // checksum is at 148th byte
    for (var i = 0; i < 6; ++i) {
      buffer[checksumIndex++] = sum_str.codeUnits[i];
    }
    buffer[checksumIndex++] = 0;
    buffer[checksumIndex++] = 32;

    if (_content != null) {
      buffer.addAll(_content as List<int>);
    } else if (_rawContent != null) {
      buffer.addAll(_rawContent.toUint8List());
    }

    if (isFile && fileSize > 0) {
      // Pad to 512-byte boundary
      final remainder = fileSize % 512;
      if (remainder != 0) buffer.length += 512 - remainder;
    }
  }

  int _parseInt(InputStream input, int numBytes) {
    var s = _parseString(input, numBytes);
    if (s.isEmpty) {
      return 0;
    }
    var x = 0;
    try {
      x = int.parse(s, radix: 8);
    } catch (e) {
      // Catch to fix a crash with bad group_id and owner_id values.
      // This occurs for POSIX archives, where some attributes like uid and
      // gid are stored in a separate PaxHeader file.
    }
    return x;
  }

  String _parseString(InputStream input, int numBytes) {
    try {
      final codes = input.readBytes(numBytes);
      final r = codes.indexOf(0);
      final s = codes.subset(0, r < 0 ? null : r);
      final b = s.toUint8List();
      final str = String.fromCharCodes(b).trim();
      return str;
    } catch (e) {
      throw ArchiveException('Invalid Archive');
    }
  }

  void _writeString(Uint8Buffer buffer, String value, int numBytes) {
    final length = math.min(numBytes, value.length);
    buffer.addAll(value.codeUnits, 0, length);
    buffer.length += numBytes - length;
  }

  void _writeInt(Uint8Buffer buffer, int value, int numBytes) {
    buffer.addAll(value.toRadixString(8).padLeft(numBytes, '0').codeUnits);
  }
}
