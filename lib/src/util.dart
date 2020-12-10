import 'package:file/file.dart';
import 'package:path/path.dart' as p;

/// Returns [entity]'s path relative to `base` or its root, converted to POSIX
/// format.
String entityRelativePath(FileSystemEntity entity, {String base}) {
  var entityPath = entity.fileSystem.path;
  if (base != null && !entityPath.isWithin(base, entity.path)) {
    throw ArgumentError('Entity "${entity.path}" is not within "$base".');
  }

  var path = entityPath.relative(entity.path,
      from: base ?? entityPath.rootPrefix(entity.path));

  // Zip files expect paths in POSIX format, so convert it if it isn't yet.
  return entity.fileSytem.path.style == p.Style.posix
      ? path
      : p.posix.fromUri(entity.fileSytem.path.toUri(path));
}
