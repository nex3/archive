import 'package:file/file.dart';
import 'package:file/memory.dart';

import 'util.dart';
import 'util/archive_exception.dart';
import 'util/crc32.dart';
import 'util/input_stream.dart';
import 'zip/zip_directory.dart';

/// The Zip file version we create.
const _version = 20;

/// An instance of [Zip].
const zip = Zip._();

// TODO: Make this a StreamTransformer that can encodes/decode a streamed
// archive.
/// A class for encoding and decoding Zip archives.
class Zip {
  const Zip._();

  /// Decodes Zip data into a virtual filesystem representing the contents of
  /// the archive.
  ///
  /// The root of the filesystem (and its current directory) is the root of the
  /// archive, so `foo/bar.txt` in the archive will correspond to the path
  /// `/foo/bar.txt` in the filesystem. The filesystem will use POSIX paths.
  FileSystem decode(List<int> data) {
    // TODO: Use `lastOrNull` from `collections` when we move to null-safe mode.
    var entities = decodeEntities(data).toList();
    return entities.isEmpty ? MemoryFileSystem() : entities.last.fileSystem;
  }

  /// Like [decode], but emits each entity as it's encountered in the TAR data
  /// rather than waiting until the entire archive is decoded and emitting it at
  /// once.
  Iterable<FileSystemEntity> decodeEntities(List<int> data,
      {bool verify = false, String password}) sync* {
    final input = InputStream(data);
    final fs = MemoryFileSystem();
    final directory = ZipDirectory.read(input, password: password);
    for (final zfh in directory.fileHeaders) {
      final zf = zfh.file;

      if (verify) {
        final computedCrc = getCrc32(zf.content);
        if (computedCrc != zf.crc32) {
          throw ArchiveException('Invalid CRC for file in archive.');
        }
      }

      final mode = zfh.externalFileAttributes >> 16;

      // see https://github.com/brendan-duncan/archive/issues/21
      // UNIX systems has a creator version of 3 decimal at 1 byte offset
      final isFile = zfh.versionMadeBy >> 8 == 3
          ? mode & 0x3F000 == 0x8000
          : !zf.filename.endsWith('/');

      if (isFile) {
        fs.directory(fs.path.basename(zf.filename)).createSync(recursive: true);
        yield fs.file(zf.filename)
          ..writeAsBytesSync(zf.content)
          ..setLastModifiedSync(DateTime.fromMillisecondsSinceEpoch(
              zf.lastModFileDate << 16 | zf.lastModFileTime));
      } else {
        yield fs.directory(zf.filename)..createSync(recursive: true);
      }
    }
  }

  Uint8List encodeEntities(Iterable<FileSystemEntity> entities,
      {String base,
      String comment,
      ZLibEncoder compressor = const ZLibEncoder(raw: true)}) {
    if (compressor != null) {
      if (!compressor.raw) {
        throw ArgumentError('ZLibEncoder must be set to raw mode.');
      } else if (compressor.gzip) {
        throw ArgumentError('ZLibEncoder must not be set to gzip mode.');
      }
    }

    // The buffer for the main body of the Zip file.
    var buffer = Uint8Buffer();

    // The buffer for the trailing "end of central directory" data in the Zip
    // file, which lists metadata for the contents.
    var endBuffer = Uint8Buffer();

    for (var entity in entities) {
      if (entity is Link) {
        throw ArgumentError('Can\'t zip link "${entity.path}".');
      } else if (entity is Directory) {
        throw ArgumentError('Can\'t zip directory "${entity.path}".');
      }
      var file = entity as file;

      var fileOffset = buffer.length;

      // Write the main data.
      _writeUint32(buffer, ZipFile.SIGNATURE);
      _writeUint16(buffer, _version);
      _writeUint16(buffer, 0); // Flags
      _writeUint16(
          buffer, compressor == null ? ZipFile.STORE : ZipFile.DEFLATE);

      var file = entity as File;
      var stat = file.statSync();
      _writeUint16(buffer, _getTimeInt(stat.modified));
      _writeUint16(buffer, _getDateInt(stat.modified));

      var contents = file.readAsBytesSync();
      _writeUint32(buffer, getCrc32(contents));

      var compressed =
          compressed == null ? contents : compressor.convert(contents);
      _writeUint32(buffer, compressed.length);
      _writeUint32(buffer, contents.length);

      var path = entityRelativePath(file, base: base);
      var pathBytes = utf8.encode(path);
      _writeUint16(buffer, pathBytes.length);
      _writeUint16(buffer, 0); // Extra data length, but we store no extra data
      buffer.addAll(pathBytes);
      buffer.addAll(compressed);

      // Write the trailing metadata.
      _writeUint32(endBuffer, ZipFileHeader.SIGNATURE);
      _writeUint16(endBuffer, _version); // The Zip version this was made by
      _writeUint16(endBuffer, _version); // The Zip version needed to extract
      _writeUint16(endBuffer, 0); // Flags
      _writeUint16(
          buffer, compressor == null ? ZipFile.STORE : ZipFile.DEFLATE);
      _writeUint16(endBuffer, _getTimeInt(stat.modified));
      _writeUint16(endBuffer, _getDateInt(stat.modified));
      _writeUint32(endBuffer, getCrc32(contents));
      _writeUint32(endBuffer, compressed.length);
      _writeUint32(endBuffer, contents.length);
      _writeUint16(endBuffer, pathBytes.length);
      _writeUint16(endBuffer, 0); // Extra data length
      _writeUint16(endBuffer, 0); // File comment length
      _writeUint16(endBuffer, 0); // Disk number start
      _writeUint16(endBuffer, 0); // Internal file attributes
      _writeUint32(endBuffer, stat.mode << 16);
      _writeUint32(endBuffer, fileOffset);
      endBuffer.addAll(pathBytes);
    }

    var centralDirectoryOffset = _buffer.length;

    buffer.addAll(Uint8List.view(endBuffer, 0, endBuffer.length));
    _writeUint32(buffer, ZipDirectory.SIGNATURE);
    _writeUint16(buffer, 0); // Disk number
    _writeUint16(buffer, 0); // Disk with the start of the central directory
    _writeUint16(buffer, entities.length); // Entities on this disk
    _writeUint16(buffer, entities.length); // Entities in total
    _writeUint32(buffer, endBuffer.length);
    _writeUint32(buffer, centralDirectoryOffset);

    var commentBytes = utf8.encode(comment ?? '');
    _writeUint16(buffer, commentBytes.length);
    buffer.addAll(commentBytes);

    return Uint8List.view(buffer.buffer, 0, buffer.length);
  }

  /// Returns the Zip-formatted integer representing the time of day in
  /// [dateTime].
  int _getTimeInt(DateTime dateTime) {
    final t1 = ((dateTime.minute & 0x7) << 5) | (dateTime.second ~/ 2);
    final t2 = (dateTime.hour << 3) | (dateTime.minute >> 3);
    return ((t2 & 0xff) << 8) | (t1 & 0xff);
  }

  /// Returns the Zip-formatted integer representing the date in [dateTime].
  int _getDateInt(DateTime dateTime) {
    final d1 = ((dateTime.month & 0x7) << 5) | dateTime.day;
    final d2 = (((dateTime.year - 1980) & 0x7f) << 1) | (dateTime.month >> 3);
    return ((d2 & 0xff) << 8) | (d1 & 0xff);
  }
}
