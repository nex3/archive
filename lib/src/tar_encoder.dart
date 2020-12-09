import 'dart:typed_data';

import 'package:typed_data/typed_data.dart';

import 'tar/tar_file.dart';
import 'archive.dart';
import 'archive_file.dart';

/// Encode an [Archive] object into a tar formatted buffer.
class TarEncoder {
  Uint8Buffer _buffer;

  List<int> encode(Archive archive) {
    final buffer = Uint8Buffer();
    start(buffer);

    for (final file in archive.files) {
      add(file);
    }

    finish();

    return Uint8List.view(buffer.buffer, 0, buffer.length);
  }

  void start([Uint8Buffer buffer]) {
    _buffer = buffer ?? Uint8Buffer();
  }

  void add(ArchiveFile file) {
    if (_buffer == null) {
      return;
    }

    // GNU tar files store extra long file names in a separate file
    if (file.name.length > 100) {
      final ts = TarFile();
      ts.filename = '././@LongLink';
      ts.fileSize = file.name.length;
      ts.mode = 0;
      ts.ownerId = 0;
      ts.groupId = 0;
      ts.lastModTime = 0;
      ts.content = file.name.codeUnits;
      ts.write(_buffer);
    }

    final ts = TarFile();
    ts.filename = file.name;
    ts.fileSize = file.size;
    ts.mode = file.mode;
    ts.ownerId = file.ownerId;
    ts.groupId = file.groupId;
    ts.lastModTime = file.lastModTime;
    ts.content = file.content;
    ts.write(_buffer);
  }

  void finish() {
    // At the end of the archive file there are two 512-byte blocks filled
    // with binary zeros as an end-of-file marker.
    _buffer.length += 1024;
    _buffer = null;
  }
}
