import 'dart:io';

import 'package:archive/archive.dart';

void main() {
  // Read the Zip file from disk.
  final bytes = File('test.zip').readAsBytesSync();

  // Decode the Zip file
  final archive = ZipDecoder().decodeBytes(bytes);

  // Extract the contents of the Zip archive to disk.
  for (final file in archive) {
    final filename = file.name;
    if (file.isFile) {
      final data = file.content as List<int>;
      File('out/' + filename)
        ..createSync(recursive: true)
        ..writeAsBytesSync(data);
    } else {
      Directory('out/' + filename).create(recursive: true);
    }
  }

  // Encode the archive as a GZip compressed Tar file.
  final tar_data = TarEncoder().encode(archive);
  final tar_gz = gzip.encode(tar_data);

  // Write the compressed tar file to disk.
  final fp = File('test.tgz');
  fp.writeAsBytesSync(tar_gz);
}
