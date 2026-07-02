/// Default log sink on platforms without `dart:io` (e.g. web): writes each
/// line via `print`, so structured logs stay visible in the browser console.
StringSink defaultLogSink() => _PrintSink();

class _PrintSink implements StringSink {
  @override
  void write(Object? obj) => print(obj);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      print(objects.join(separator));

  @override
  void writeCharCode(int charCode) => print(String.fromCharCode(charCode));

  @override
  void writeln([Object? obj = '']) => print(obj);
}
