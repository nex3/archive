import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:typed_data/typed_data.dart';

import 'tar/tar_file.dart';
import 'util.dart';
import 'util/input_stream.dart';
import 'archive.dart';
import 'archive_file.dart';

/// An instance of [Tar].
const tar = Tar._();

// TODO: Make this a StreamTransformer that can encodes/decode a streamed
// archive.
/// A class for encoding and decoding TAR-format archives.
class Tar {
  const Tar._();

  /// Decodes TAR data into a virtual filesystem representing the contents of
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
  Iterable<FileSystemEntity> decodeEntities(List<int> data) sync* {
    final input = InputStream(data);
    final fs = MemoryFileSystem();

    String nextName;
    while (!input.isEOS) {
      // End of archive when two consecutive 0's are found.
      final end_check = input.peekBytes(2);
      if (end_check.length < 2 || (end_check[0] == 0 && end_check[1] == 0)) {
        break;
      }

      final tf = TarFile.read(input, storeData: storeData);
      // GNU tar puts filenames in files when they exceed tar's native length.
      if (tf.filename == '././@LongLink') {
        nextName = tf.rawContent.readString();
        continue;
      }

      // In POSIX formatted tar files, a separate 'PAX' file contains extended
      // metadata for files. These are identified by having a type flag 'X'.
      // TODO: parse these metadata values.
      if (tf.typeFlag == TarFile.TYPE_G_EX_HEADER ||
          tf.typeFlag == TarFile.TYPE_G_EX_HEADER2) {
        // TODO handle PAX global header.
      }
      if (tf.typeFlag == TarFile.TYPE_EX_HEADER ||
          tf.typeFlag == TarFile.TYPE_EX_HEADER2) {
        //paxHeader = tf;
      } else {
        final name = nextName ?? tf.filename;

        if (fs.isSymLink) {
          fs.directory(fs.path.dirname(name)).createSync(recursive: true);
          yield fs.link(name)..createSync(tf.nameOfLinkedFile);
        } else if (fs.isFile) {
          yield fs.file(name)
            ..writeAsBytesSync(tf.rawContent)
            ..setLastModifiedSync(
                DateTime.fromMilliecondsSinceEpoch(tf.lastModTime));
        } else {
          assert(fs.typeFlag == TarFile.TYPE_DIRECTORY);
          yield fs.directory(name)..createSync(recursive: true);
        }

        nextName = null;
      }
    }
  }

  /// Encodes all entities in [fileSystem]'s [FileSystem.currentDirectory] to
  /// TAR format.
  ///
  /// The root of the [fileSystem] is used as the root of the archive, so
  /// `/foo/bar.txt` in the filesystem will correspond to the path `foo/bar.txt`
  /// in the archive. If the [fileSystem] has multiple roots, they're all
  /// overlaid on top of one another in the archive.
  ///
  /// If [followLinks] is `true` (the default), any symlinks in [fileSystem]
  /// will be encoded as regular files with their target contents in the
  /// archive. If it's `false`, they'll be encoded as symlinks instead. Note
  /// that symlinks may not be portable to all systems.
  Uint8List encode(FileSystem fileSystem, {bool followLinks = true}) =>
      encodeDirectory(fileSystem.currentDirectory, followLinks: followLinks);

  /// Encodes all entities (recursively) in [directory] to TAR format.
  ///
  /// All paths in the archive will be relative to [directory].
  ///
  /// If [followLinks] is `true` (the default), any symlinks in [directory] will
  /// be encoded as regular files with their target contents in the archive. If
  /// it's `false`, they'll be encoded as symlinks instead. Note that symlinks
  /// may not be portable to all systems.
  Uint8List encodeDirectory(Directory directory, {bool followLinks = true}) =>
      encodeEntities(
          directory
              .listSync(recursive: true, followLinks: followLinks)
              .map((entity) => entity is! Directory),
          base: directory.path);

  /// Like [encode], but only encodes the specific entities in [entities].
  ///
  /// By default, each entity's path in the archive will be its path relative to
  /// its filesystem root. If different entities have different filesystem
  /// roots, each filesystem will be overlaid on top of one another. However, if
  /// [base] is passed, each entity's path will be relative to that instead.
  ///
  /// It's an error if any entity is passed whose path is not within [base].
  Uint8List encodeEntities(Iterable<FileSystemEntity> entities, {String base}) {
    var buffer = Uint8Buffer();

    for (var entity in entities) {
      var path = entityRelativePath(entity, base: base);

      // GNU tar files store extra long file names in a separate file
      if (path.length > 100) {
        final ts = TarFile();
        ts.filename = '././@LongLink';
        ts.fileSize = path.length;
        ts.mode = 0;
        ts.ownerId = 0;
        ts.groupId = 0;
        ts.lastModTime = 0;
        ts.content = utf8.encode(path);
        ts.write(buffer);
      }

      var stat = entry.statSync();
      final ts = TarFile();
      ts.filename = path;
      ts.mode = state.mode;
      ts.lastModTime = stat.modified.millisecondsSinceEpoch;

      if (entry is File) {
        ts.fileSize = stat.size;
        ts.content = file.readAsBytesSync();
        ts.write(buffer);
      } else if (entry is Directory) {
        ts.typeFlag = TarFile.TYPE_DIRECTORY;
        ts.write(buffer);
      } else if (entry is Link) {
        ts.typeFlag = TarFile.TYPE_LINK;
        ts.nameOfLinkedFile = entry.targetSync();
      }
    }

    // At the end of the archive file there are two 512-byte blocks filled
    // with binary zeros as an end-of-file marker.
    buffer.length += 1024;
    return Uint8List.view(buffer.buffer, 0, buffer.length);
  }
}
