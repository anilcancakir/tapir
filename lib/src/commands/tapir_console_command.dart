import 'dart:convert';

import 'package:dowel/dowel.dart';

import 'frame_warning_output.dart';

/// `dowel tapir:console [--limit=<n>] [--minLevel=<level>] [--grep=<text>]
/// [--logger=<name>]`: read recent log entries from tapir's `debugPrint`
/// capture, plus crumbs when it is wired.
///
/// Wraps the `ext.tapir.console` VM Service extension. The Dart-side reader
/// reads through `CrumbsStore.recentLogs(...)` when
/// `crumbs` is wired (host sets `recentLogsReader`); otherwise
/// an empty list is returned (missing-crumbs graceful path).
class TapirConsoleCommand extends DowelCommand {
  @override
  String get name => 'tapir:console';

  @override
  String get description =>
      'Read recent log entries from tapir\'s log capture of debugPrint '
      'output, plus crumbs when it is wired.';

  @override
  CommandBoot get boot => CommandBoot.connected;

  @override
  void configure(ArgParser parser) {
    parser.addOption(
      'limit',
      help: 'Maximum number of log entries to return (default 50).',
      defaultsTo: '50',
    );
    parser.addOption(
      'minLevel',
      help: 'Minimum severity level to include (e.g. WARNING, ERROR).',
    );
    parser.addOption(
      'grep',
      help:
          'Only entries whose message contains this text '
          '(case-insensitive). Applied before --limit.',
    );
    parser.addOption(
      'logger',
      help:
          'Only entries from this exact logger name (debugPrint output '
          'is logger "debugPrint"). Applied before --limit.',
    );
  }

  @override
  Future<int> handle(DowelContext ctx) async {
    final String? limit = ctx.input.option('limit') as String?;
    final String? minLevel = ctx.input.option('minLevel') as String?;
    final String? grep = ctx.input.option('grep') as String?;
    final String? logger = ctx.input.option('logger') as String?;

    final params = <String, dynamic>{};
    if (limit != null && limit.isNotEmpty) {
      params['limit'] = limit;
    }
    if (minLevel != null && minLevel.isNotEmpty) {
      params['minLevel'] = minLevel;
    }
    if (grep != null && grep.isNotEmpty) {
      params['grep'] = grep;
    }
    if (logger != null && logger.isNotEmpty) {
      params['logger'] = logger;
    }

    final response = await ctx.callExtension<Map<String, dynamic>>(
      'ext.tapir.console',
      params,
    );
    reportFrameWarning(ctx, response);
    ctx.output.writeln(jsonEncode(response));
    return 0;
  }
}
