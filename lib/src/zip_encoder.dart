import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:typed_data/typed_data.dart';

import 'util/crc32.dart';
import 'util/input_stream.dart';
import 'zip/zip_directory.dart';
import 'zip/zip_file.dart';
import 'zip/zip_file_header.dart';
import 'archive.dart';
import 'archive_file.dart';

class _ZipFileData {
  String name;
  int time = 0;
  int date = 0;
  int crc32 = 0;
  int compressedSize = 0;
  int uncompressedSize = 0;
  InputStreamBase compressedData;
  bool compress = true;
  String comment = '';
  int position = 0;
  int mode = 0;
  bool isFile = true;
}

class _ZipEncoderData {
  int level;
  int time;
  int date;
  int localFileSize = 0;
  int centralDirectorySize = 0;
  int endOfCentralDirectorySize = 0;
  List<_ZipFileData> files = [];

  _ZipEncoderData([int level]) : level = level ?? ZLibOption.defaultLevel {
    final dateTime = DateTime.now();
    final t1 = ((dateTime.minute & 0x7) << 5) | (dateTime.second ~/ 2);
    final t2 = (dateTime.hour << 3) | (dateTime.minute >> 3);
    time = ((t2 & 0xff) << 8) | (t1 & 0xff);

    final d1 = ((dateTime.month & 0x7) << 5) | dateTime.day;
    final d2 = (((dateTime.year - 1980) & 0x7f) << 1) | (dateTime.month >> 3);
    date = ((d2 & 0xff) << 8) | (d1 & 0xff);
  }
}

/// Encode an [Archive] object into a Zip formatted buffer.
class ZipEncoder {
  _ZipEncoderData _data;
  Uint8Buffer _buffer;

  List<int> encode(Archive archive, {int level, Uint8Buffer buffer}) {
    buffer ??= Uint8Buffer();

    startEncode(buffer, level: level);
    for (final file in archive.files) {
      addFile(file);
    }
    endEncode(comment: archive.comment);
    return Uint8List.view(buffer.buffer, 0, buffer.length);
  }

  void startEncode(Uint8Buffer buffer, {int level}) {
    _data = _ZipEncoderData(level);
    _buffer = buffer;
  }

  int getFileCrc32(ArchiveFile file) {
    if (file.content is InputStreamBase) {
      var s = file.content as InputStreamBase;
      s.reset();
      var bytes = s.toUint8List();
      final crc32 = getCrc32(bytes);
      file.content.reset();
      return crc32;
    }
    return getCrc32(file.content as List<int>);
  }

  void addFile(ArchiveFile file) {
    final fileData = _ZipFileData();
    _data.files.add(fileData);

    fileData.name = file.name;
    fileData.time = _data.time;
    fileData.date = _data.date;
    fileData.mode = file.mode ?? 0;
    fileData.isFile = file.isFile;

    InputStreamBase compressedData;
    int crc32;

    // If the user want's to store the file without compressing it,
    // make sure it's decompressed.
    if (!file.compress) {
      if (file.isCompressed) {
        file.decompress();
      }

      compressedData = (file.content is InputStreamBase)
          ? file.content as InputStreamBase
          : InputStream(file.content);

      if (file.crc32 != null) {
        crc32 = file.crc32;
      } else {
        crc32 = getFileCrc32(file);
      }
    } else if (file.isCompressed &&
        file.compressionType == ArchiveFile.DEFLATE) {
      // If the file is already compressed, no sense in uncompressing it and
      // compressing it again, just pass along the already compressed data.
      compressedData = file.rawContent;

      if (file.crc32 != null) {
        crc32 = file.crc32;
      } else {
        crc32 = getFileCrc32(file);
      }
    } else {
      // Otherwise we need to compress it now.
      crc32 = getFileCrc32(file);

      dynamic bytes = file.content;
      if (bytes is InputStreamBase) {
        bytes = bytes.toUint8List();
      }
      bytes = ZLibEncoder(level: _data.level, raw: true)
          .convert(bytes as List<int>);
      compressedData = InputStream(bytes);
    }

    var filename = Utf8Encoder().convert(file.name);
    var comment =
        file.comment != null ? Utf8Encoder().convert(file.comment) : null;

    _data.localFileSize += 30 + filename.length + compressedData.length;

    _data.centralDirectorySize +=
        46 + filename.length + (comment != null ? comment.length : 0);

    fileData.crc32 = crc32;
    fileData.compressedSize = compressedData.length;
    fileData.compressedData = compressedData;
    fileData.uncompressedSize = file.size;
    fileData.compress = file.compress;
    fileData.comment = file.comment;
    fileData.position = _buffer.length;

    _writeFile(fileData, _buffer);

    fileData.compressedData = null;
  }

  void endEncode({String comment = ''}) {
    // Write Central Directory and End Of Central Directory
    _writeCentralDirectory(_data.files, comment, _buffer);
  }

  void _writeFile(_ZipFileData fileData, Uint8Buffer buffer) {
    var filename = fileData.name;

    _writeUint32(buffer, ZipFile.SIGNATURE);

    final version = VERSION;
    final flags = 0;
    final compressionMethod =
        fileData.compress ? ZipFile.DEFLATE : ZipFile.STORE;
    final lastModFileTime = fileData.time;
    final lastModFileDate = fileData.date;
    final crc32 = fileData.crc32;
    final compressedSize = fileData.compressedSize;
    final uncompressedSize = fileData.uncompressedSize;
    final extra = <int>[];

    final compressedData = fileData.compressedData;

    var filenameUtf8 = Utf8Encoder().convert(filename);

    _writeUint16(buffer, version);
    _writeUint16(buffer, flags);
    _writeUint16(buffer, compressionMethod);
    _writeUint16(buffer, lastModFileTime);
    _writeUint16(buffer, lastModFileDate);
    _writeUint32(buffer, crc32);
    _writeUint32(buffer, compressedSize);
    _writeUint32(buffer, uncompressedSize);
    _writeUint16(buffer, filenameUtf8.length);
    _writeUint16(buffer, extra.length);
    buffer.addAll(filenameUtf8);
    buffer.addAll(extra);

    buffer.addAll(compressedData.toUint8List());
  }

  void _writeCentralDirectory(
      List<_ZipFileData> files, String comment, Uint8Buffer buffer) {
    comment ??= '';
    var commentUtf8 = Utf8Encoder().convert(comment);

    final centralDirPosition = buffer.length;
    final version = VERSION;
    final os = OS_MSDOS;

    for (var fileData in files) {
      final versionMadeBy = (os << 8) | version;
      final versionNeededToExtract = version;
      final generalPurposeBitFlag = 0;
      final compressionMethod =
          fileData.compress ? ZipFile.DEFLATE : ZipFile.STORE;
      final lastModifiedFileTime = fileData.time;
      final lastModifiedFileDate = fileData.date;
      final crc32 = fileData.crc32;
      final compressedSize = fileData.compressedSize;
      final uncompressedSize = fileData.uncompressedSize;
      final diskNumberStart = 0;
      final internalFileAttributes = 0;
      final externalFileAttributes = fileData.mode << 16;
      /*if (!fileData.isFile) {
        externalFileAttributes |= 0x4000; // ?
      }*/
      final localHeaderOffset = fileData.position;
      final extraField = <int>[];
      final fileComment = fileData.comment ?? '';

      final filenameUtf8 = Utf8Encoder().convert(fileData.name);
      final fileCommentUtf8 = Utf8Encoder().convert(fileComment);

      _writeUint32(buffer, ZipFileHeader.SIGNATURE);
      _writeUint16(buffer, versionMadeBy);
      _writeUint16(buffer, versionNeededToExtract);
      _writeUint16(buffer, generalPurposeBitFlag);
      _writeUint16(buffer, compressionMethod);
      _writeUint16(buffer, lastModifiedFileTime);
      _writeUint16(buffer, lastModifiedFileDate);
      _writeUint32(buffer, crc32);
      _writeUint32(buffer, compressedSize);
      _writeUint32(buffer, uncompressedSize);
      _writeUint16(buffer, filenameUtf8.length);
      _writeUint16(buffer, extraField.length);
      _writeUint16(buffer, fileCommentUtf8.length);
      _writeUint16(buffer, diskNumberStart);
      _writeUint16(buffer, internalFileAttributes);
      _writeUint32(buffer, externalFileAttributes);
      _writeUint32(buffer, localHeaderOffset);
      buffer.addAll(filenameUtf8);
      buffer.addAll(extraField);
      buffer.addAll(fileCommentUtf8);
    }

    final numberOfThisDisk = 0;
    final diskWithTheStartOfTheCentralDirectory = 0;
    final totalCentralDirectoryEntriesOnThisDisk = files.length;
    final totalCentralDirectoryEntries = files.length;
    final centralDirectorySize = buffer.length - centralDirPosition;
    final centralDirectoryOffset = centralDirPosition;

    _writeUint32(buffer, ZipDirectory.SIGNATURE);
    _writeUint16(buffer, numberOfThisDisk);
    _writeUint16(buffer, diskWithTheStartOfTheCentralDirectory);
    _writeUint16(buffer, totalCentralDirectoryEntriesOnThisDisk);
    _writeUint16(buffer, totalCentralDirectoryEntries);
    _writeUint32(buffer, centralDirectorySize);
    _writeUint32(buffer, centralDirectoryOffset);
    _writeUint16(buffer, commentUtf8.length);
    buffer.addAll(commentUtf8);
  }

  /// Writes [number] to [buffer] as a 16-bit little-endian number.
  void _writeUint16(Uint8Buffer buffer, int number) {
    assert(number < 0x10000);
    buffer.add(number & 0xff);
    buffer.add((number >> 8) & 0xff);
  }

  /// Writes [number] to [buffer] as a 32-bit little-endian number.
  void _writeUint32(Uint8Buffer buffer, int number) {
    assert(number < 0x100000000);
    buffer.add(number & 0xff);
    buffer.add((number >> 8) & 0xff);
    buffer.add((number >> 16) & 0xff);
    buffer.add((number >> 24) & 0xff);
  }

  static const int VERSION = 20;

  // enum OS
  static const int OS_MSDOS = 0;
  static const int OS_UNIX = 3;
  static const int OS_MACINTOSH = 7;
}
