import 'package:modular_api/modular_api.dart';

// ─── Input DTO ────────────────────────────────────────────────────────────────

class CurrentTimeInput extends Input {
  final String tz;

  CurrentTimeInput({this.tz = ''});

  @override
  Map<String, dynamic> toJson() => {'tz': tz};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.optional(
          SchemaField.string('tz',
              description: 'Timezone offset (e.g. utc-5, utc+3, utc)',
              example: 'utc-5'),
        ),
      ];

  static CurrentTimeInput get example => CurrentTimeInput(tz: 'utc-5');
}

// ─── Output DTO ───────────────────────────────────────────────────────────────

class CurrentTimeOutput extends Output {
  final String datetime;
  final int offset;

  CurrentTimeOutput({required this.datetime, required this.offset});

  @override
  int get statusCode => 200;

  @override
  Map<String, dynamic> toJson() => {'datetime': datetime, 'offset': offset};

  @override
  List<SchemaField> get schemaFields => [
        SchemaField.string('datetime',
            description: 'ISO 8601 datetime at the requested offset',
            example: '2026-03-14T07:00:00'),
        SchemaField.integer('offset',
            description: 'UTC offset in hours', example: -5),
      ];

  static CurrentTimeOutput get example =>
      CurrentTimeOutput(datetime: '2026-03-14T07:00:00', offset: -5);
}

// ─── UseCase ──────────────────────────────────────────────────────────────────

class CurrentTime implements UseCase<CurrentTimeInput, CurrentTimeOutput> {
  @override
  final CurrentTimeInput input;

  @override
  ModularLogger? logger;

  CurrentTime({required this.input});

  static CurrentTime fromJson(Map<String, dynamic> json) {
    return CurrentTime(
        input: CurrentTimeInput(tz: (json['tz'] ?? '').toString()));
  }

  @override
  String? validate() {
    if (input.tz.isEmpty) return null;
    final offset = _parseOffset(input.tz);
    if (offset == null) return 'invalid timezone format, use utc, utc-5, utc+3';
    if (offset < -12 || offset > 14) {
      return 'offset must be between -12 and +14';
    }
    return null;
  }

  @override
  Future<CurrentTimeOutput> execute() async {
    final now = DateTime.now().toUtc();
    final offsetHours = input.tz.isEmpty
        ? DateTime.now().timeZoneOffset.inHours
        : _parseOffset(input.tz)!;
    final adjusted = now.add(Duration(hours: offsetHours));
    final iso = adjusted.toIso8601String().split('.').first;

    logger?.info('Time requested for offset $offsetHours');
    return CurrentTimeOutput(datetime: iso, offset: offsetHours);
  }

  /// Parses "utc-5", "utc+3", "utc" into an integer offset. Returns null on bad format.
  static int? _parseOffset(String tz) {
    final lower = tz.toLowerCase().trim();
    if (lower == 'utc') return 0;
    final match = RegExp(r'^utc([+-]\d{1,2})$').firstMatch(lower);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }
}
