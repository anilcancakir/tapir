import 'dart:developer' as developer;

import 'package:dowel/dowel.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../tapir_log_capture.dart';
import '../utils/tapir_register.dart';
import '../utils/tapir_response.dart';
import '../utils/error_envelope.dart';

// ---------------------------------------------------------------------------
// MCP descriptor constants — consumed by TapirDowelProvider.mcpTools()
// ---------------------------------------------------------------------------

/// MCP tool name for the console log reader.
const String kTapirConsoleMcpName = 'tapir_console';

/// VM Service extension method name for the console log reader.
const String kTapirConsoleMcpExtension = 'ext.tapir.console';

// ---------------------------------------------------------------------------
// Function-pointer indirection — same pattern as pendingHttpCountReader
// ---------------------------------------------------------------------------

/// What `ext.tapir.console` asks [recentLogsReader] for.
///
/// One object rather than named parameters, so a filter added later is a new
/// field with a default and a reader assigned today keeps compiling.
@immutable
final class ConsoleRequest {
  /// A request for up to [limit] entries at [minLevel] or above.
  const ConsoleRequest({
    this.limit = 50,
    this.minLevel,
    this.grep,
    this.logger,
  });

  /// The most entries to return. A reader keeps the newest [limit] and may
  /// return them in either order: the handler orders the merged result
  /// newest-first itself.
  final int limit;

  /// The lowest `package:logging` level name to include (`INFO`, `WARNING`,
  /// `SEVERE`, ...); null includes every level.
  final String? minLevel;

  /// A case-insensitive substring the entry `message` must contain; null
  /// includes every message. The handler re-applies it to the merged list, so
  /// a reader that ignores it stays correct.
  final String? grep;

  /// The exact logger name an entry must carry; null includes every logger.
  /// The handler re-applies it to the merged list, like [grep].
  final String? logger;
}

/// The `limit` asked of [recentLogsReader] while a `grep` or `logger` filter is
/// active: readers clip to `request.limit` before the handler can filter, so
/// the handler asks for the whole store and clips after filtering.
const int _kFilteredFetchLimit = 100000;

/// Reader for recent log entries from CrumbsStore.
///
/// Defaults to a function that returns an empty list so tapir compiles and
/// runs without crumbs present (missing-crumbs graceful path).
///
/// Hosts that ship `crumbs` wire the real source by assigning:
///
/// ```dart
/// recentLogsReader = (ConsoleRequest request) => CrumbsStore.recentLogs(
///   limit: request.limit,
///   minLevel: request.minLevel,
/// );
/// ```
///
/// The indirection keeps tapir's pubspec free of a crumbs dependency while
/// letting the console handler still read real logs when crumbs is wired.
///
/// **Contract**: set-once-per-isolate from `MagicCrumbsIntegration.install()`.
/// Reset to the empty-list default by `MagicCrumbsIntegration.resetForTesting()`
/// so downstream tests asserting the missing-crumbs default do not see leaked
/// bindings.
List<Map<String, Object?>> Function(ConsoleRequest request) recentLogsReader = (
  ConsoleRequest request,
) => const <Map<String, Object?>>[];

// ---------------------------------------------------------------------------
// Aggregator
// ---------------------------------------------------------------------------

/// Registers the `ext.tapir.console` VM Service extension.
///
/// Idempotent via [registerExtensionIdempotent]. Call from
/// [registerAllTapirExtensions] once during [TapirPlugin.install].
void registerConsoleExtensions() {
  registerTapirExtension(
    kTapirConsoleMcpExtension,
    tapirConsoleHandler,
    ensureFrames: false,
  );
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

/// Handler for the `ext.tapir.console` VM Service extension.
///
/// Merges entries from two sources, deduped by `(level, message, logger)`,
/// orders them newest-first by `time`, then clips to `limit`:
///
/// 1. [recentCapturedLogs] — in-package ring buffer fed by the [debugPrint]
///    override installed by [installLogCapture]. Present without crumbs.
///    Captures every call that routes through the [debugPrint] global callback
///    (`debugPrint(...)`, `print(...)`, any Flutter framework path). Does NOT
///    capture direct `dart:developer` `log()` calls that bypass [debugPrint].
/// 2. [recentLogsReader] — function-pointer indirection wired by
///    `MagicCrumbsIntegration.install()`. Defaults to an empty list when
///    crumbs is absent (graceful no-op). When crumbs is wired it returns
///    all log sources including `Logger.root.onRecord` from `package:logging`
///    (which covers direct `developer.log()` calls when the app configures
///    hierarchical logging).
///
/// Params (all string-valued):
/// - `limit` (optional, default 50): maximum number of log entries to return.
/// - `minLevel` (optional): minimum severity level to include (e.g. `'WARNING'`,
///   `'SEVERE'`). Applied to both sources; the in-package buffer uses the same
///   level names as `dart:logging` (INFO, WARNING, SEVERE, SHOUT, ...).
/// - `grep` (optional): case-insensitive substring the entry `message` must
///   contain.
/// - `logger` (optional): exact logger name the entry must carry
///   (`debugPrint` for the in-package buffer).
///
/// `grep` and `logger` apply to both sources before the `limit` clip.
///
/// Response JSON:
/// ```json
/// { "logs": [{"level": "INFO", "message": "...", "time": "...", "logger": "..."}], "count": 2 }
/// ```
///
/// `"capped": true` is added only once the in-package buffer has dropped its
/// oldest entries: older `debugPrint` output exists that no `limit` and no
/// filter can reach. It stays on every later reply, and does not say that this
/// reply was bounded by the buffer.
Future<developer.ServiceExtensionResponse> tapirConsoleHandler(
  String method,
  Map<String, String> params,
) async {
  try {
    // 1. Parse params: all are optional; fall back to defaults when absent.
    final int limit = _parseInt(params['limit']) ?? 50;
    final String? minLevel = params['minLevel']?.isNotEmpty == true
        ? params['minLevel']
        : null;
    final String? grep = params['grep']?.isNotEmpty == true
        ? params['grep']
        : null;
    final String? logger = params['logger']?.isNotEmpty == true
        ? params['logger']
        : null;
    final bool filtered = grep != null || logger != null;

    // 2. Collect from both sources: in-package buffer (debugPrint capture) and
    //    the crumbs reader (when wired). A reader clips to its own limit before
    //    the filters run here, so while one is active the reader is asked for
    //    its whole store and the clip happens after filtering.
    final List<Map<String, dynamic>> buffered = recentCapturedLogs(
      limit: limit,
      minLevel: minLevel,
      grep: grep,
      logger: logger,
    );
    final List<Map<String, Object?>> crumbs = recentLogsReader(
      ConsoleRequest(
        limit: filtered ? _kFilteredFetchLimit : limit,
        minLevel: minLevel,
        grep: grep,
        logger: logger,
      ),
    );

    // 3. Merge, dedup by (level, message, logger), apply the filters a reader
    //    may have ignored, order newest-first by time (a reader may return
    //    either order), then clip to limit. Crumbs entries are ordered first so
    //    dedup keeps the newest occurrence of a repeat, and buffered entries
    //    stay ahead of them so they win a cross-source duplicate.
    final Set<String> seen = <String>{};
    final List<Map<String, dynamic>> merged = <Map<String, dynamic>>[];

    for (final Map<String, dynamic> entry in <Map<String, dynamic>>[
      ...buffered,
      ..._newestFirst(crumbs),
    ]) {
      final String key =
          '${entry['level']} ${entry['message']} ${entry['logger']}';
      if (matchesLogFilters(entry, grep: grep, logger: logger) &&
          seen.add(key)) {
        merged.add(entry);
      }
    }

    final List<Map<String, dynamic>> ordered = _newestFirst(merged);
    final List<Map<String, dynamic>> logs = ordered.length > limit
        ? ordered.sublist(0, limit)
        : ordered;

    // 4. Return the structured envelope — count lets callers skip iterating the
    //    list when only the total matters. `capped` is added only when the
    //    capture buffer evicted entries, so a healthy reply is unchanged.
    return tapirResult(<String, dynamic>{
      'logs': logs,
      'count': logs.length,
      if (capturedLogsEvicted) 'capped': true,
    });
  } catch (e, st) {
    developer.log(
      '[tapir] ext.tapir.console: unexpected error: $e\n$st',
      name: 'tapir',
    );
    return tapirError('ext.tapir.console: $e', TapirErrorEnvelope.unexpected());
  }
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Returns [entries] ordered newest-first by their `time` field.
///
/// The in-package buffer stamps UTC ISO strings and crumbs local ones without
/// an offset; both parse. The sort is stable (the original index breaks ties),
/// and an entry whose `time` is missing or unparseable follows every dated one,
/// keeping its relative position.
List<Map<String, dynamic>> _newestFirst(List<Map<String, dynamic>> entries) {
  final List<(int, DateTime?, Map<String, dynamic>)> indexed =
      <(int, DateTime?, Map<String, dynamic>)>[
        for (int i = 0; i < entries.length; i++)
          (i, DateTime.tryParse('${entries[i]['time']}'), entries[i]),
      ];

  indexed.sort((
    (int, DateTime?, Map<String, dynamic>) a,
    (int, DateTime?, Map<String, dynamic>) b,
  ) {
    final DateTime? aTime = a.$2;
    final DateTime? bTime = b.$2;
    if (aTime == null && bTime == null) return a.$1.compareTo(b.$1);
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    final int byTime = bTime.compareTo(aTime);
    return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
  });

  return <Map<String, dynamic>>[
    for (final (int, DateTime?, Map<String, dynamic>) item in indexed) item.$3,
  ];
}

/// Parses [raw] as a positive integer. Returns null when null, empty, or
/// not a valid integer.
int? _parseInt(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return int.tryParse(raw);
}
