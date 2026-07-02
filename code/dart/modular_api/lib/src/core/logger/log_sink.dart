/// Resolves the default [StringSink] for log output in a platform-safe way.
///
/// On `dart:io` platforms (server, mobile, desktop) this is `stdout`; on web
/// it falls back to a `print`-based sink. The conditional export keeps
/// `dart:io` out of the import graph when compiling for web.
library;

export 'log_sink_stub.dart' if (dart.library.io) 'log_sink_io.dart';
