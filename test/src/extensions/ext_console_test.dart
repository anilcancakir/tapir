import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tapir/src/tapir_log_capture.dart';
import 'package:tapir/src/extensions/ext_console.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ext_console — recentLogsReader function-pointer indirection', () {
    setUp(() {
      // Reset the reader to the default (empty list) and clear the in-package
      // buffer so tests start from a known state.
      recentLogsReader = (ConsoleRequest request) => const [];
      resetCapturedLogsForTesting();
    });

    tearDown(resetCapturedLogsForTesting);

    // -------------------------------------------------------------------------
    // (a) Default reader returns empty list — missing-crumbs graceful path.
    // -------------------------------------------------------------------------

    test('(a) default reader returns empty list and count 0', () async {
      final response = await tapirConsoleHandler(
        'ext.tapir.console',
        <String, String>{},
      );

      expect(response.result, isNotNull);
      final Map<String, dynamic> decoded =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(decoded['logs'], isA<List>());
      expect((decoded['logs'] as List).isEmpty, isTrue);
      expect(decoded['count'], equals(0));
    });

    // -------------------------------------------------------------------------
    // (b) Custom reader wired — default limit 50 forwarded.
    // -------------------------------------------------------------------------

    test(
      '(b) wires through default limit=50 when no limit param supplied',
      () async {
        int? capturedLimit;
        String? capturedMinLevel;
        recentLogsReader = (ConsoleRequest request) {
          capturedLimit = request.limit;
          capturedMinLevel = request.minLevel;
          return const [];
        };

        await tapirConsoleHandler('ext.tapir.console', <String, String>{});

        expect(capturedLimit, equals(50));
        expect(capturedMinLevel, isNull);
      },
    );

    // -------------------------------------------------------------------------
    // (c) Custom limit param is forwarded to the reader.
    // -------------------------------------------------------------------------

    test('(c) custom limit param forwarded to reader', () async {
      int? capturedLimit;
      recentLogsReader = (ConsoleRequest request) {
        capturedLimit = request.limit;
        return const [];
      };

      await tapirConsoleHandler('ext.tapir.console', <String, String>{
        'limit': '10',
      });

      expect(capturedLimit, equals(10));
    });

    // -------------------------------------------------------------------------
    // (d) minLevel param is forwarded to the reader.
    // -------------------------------------------------------------------------

    test('(d) minLevel param forwarded to reader', () async {
      String? capturedMinLevel;
      recentLogsReader = (ConsoleRequest request) {
        capturedMinLevel = request.minLevel;
        return const [];
      };

      await tapirConsoleHandler('ext.tapir.console', <String, String>{
        'minLevel': 'WARNING',
      });

      expect(capturedMinLevel, equals('WARNING'));
    });

    // -------------------------------------------------------------------------
    // (e) Reader returning logs — response carries logs + count.
    // -------------------------------------------------------------------------

    test(
      '(e) reader returning logs: response carries correct shape and count',
      () async {
        // Oldest first, like CrumbsStore.recentLogs; the handler orders it.
        recentLogsReader = (ConsoleRequest request) => [
          {
            'level': 'WARNING',
            'message': 'watch out',
            'time': '2024-01-01T00:00:00.000Z',
            'logger': 'test.logger',
          },
          {
            'level': 'INFO',
            'message': 'hello',
            'time': '2024-01-01T00:01:00.000Z',
            'logger': 'test.logger',
          },
        ];

        final response = await tapirConsoleHandler(
          'ext.tapir.console',
          <String, String>{},
        );

        expect(response.result, isNotNull);
        final Map<String, dynamic> decoded =
            jsonDecode(response.result!) as Map<String, dynamic>;
        final List<dynamic> logs = decoded['logs'] as List<dynamic>;
        expect(logs, hasLength(2));
        expect(decoded['count'], equals(2));
        expect((logs.first as Map<String, dynamic>)['level'], equals('INFO'));
        expect(
          (logs.first as Map<String, dynamic>)['message'],
          equals('hello'),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // In-package buffer — crumbs ABSENT path (the D5 core scenario)
  // ---------------------------------------------------------------------------

  group('ext_console — in-package capture (crumbs absent)', () {
    setUp(() {
      // Keep crumbs reader empty so it cannot pollute assertions.
      recentLogsReader = (ConsoleRequest request) => const [];
      resetCapturedLogsForTesting();
    });

    tearDown(resetCapturedLogsForTesting);

    test(
      '(f) debugPrint after installLogCapture() appears in the console reader',
      () async {
        final DebugPrintCallback prior = debugPrint;
        addTearDown(() => debugPrint = prior);

        installLogCapture();
        addTearDown(uninstallLogCapture);

        debugPrint('captured without crumbs');

        final response = await tapirConsoleHandler(
          'ext.tapir.console',
          <String, String>{},
        );

        expect(response.result, isNotNull);
        final Map<String, dynamic> decoded =
            jsonDecode(response.result!) as Map<String, dynamic>;
        final List<dynamic> logs = decoded['logs'] as List<dynamic>;
        expect(logs, isNotEmpty);
        expect(
          (logs.first as Map<String, dynamic>)['message'],
          equals('captured without crumbs'),
        );
        expect(decoded['count'], greaterThan(0));
      },
    );

    test('(g) minLevel WARNING excludes in-package INFO entries', () async {
      final DebugPrintCallback prior = debugPrint;
      addTearDown(() => debugPrint = prior);

      installLogCapture();
      addTearDown(uninstallLogCapture);

      debugPrint('info level message');

      final response = await tapirConsoleHandler(
        'ext.tapir.console',
        <String, String>{'minLevel': 'WARNING'},
      );

      final Map<String, dynamic> decoded =
          jsonDecode(response.result!) as Map<String, dynamic>;
      final List<dynamic> logs = decoded['logs'] as List<dynamic>;
      expect(logs, isEmpty);
      expect(decoded['count'], equals(0));
    });
  });

  // ---------------------------------------------------------------------------
  // Merge + dedup — crumbs PRESENT path
  // ---------------------------------------------------------------------------

  group('ext_console — merge+dedup (crumbs present)', () {
    setUp(() {
      resetCapturedLogsForTesting();
    });

    tearDown(resetCapturedLogsForTesting);

    test(
      '(h) dedupes entries present in both in-package buffer and crumbs reader',
      () async {
        final DebugPrintCallback prior = debugPrint;
        addTearDown(() => debugPrint = prior);

        installLogCapture();
        addTearDown(uninstallLogCapture);

        // Record the same message via debugPrint (goes into in-package buffer).
        debugPrint('shared message');

        // Crumbs reader returns the same entry (same level+message+logger).
        recentLogsReader = (ConsoleRequest request) => [
          <String, dynamic>{
            'level': 'INFO',
            'message': 'shared message',
            'logger': 'debugPrint',
            'time': '2024-01-01T00:00:00.000Z',
          },
        ];

        final response = await tapirConsoleHandler(
          'ext.tapir.console',
          <String, String>{},
        );

        final Map<String, dynamic> decoded =
            jsonDecode(response.result!) as Map<String, dynamic>;
        final List<dynamic> logs = decoded['logs'] as List<dynamic>;
        // Must appear only once despite both sources containing it.
        expect(
          logs.where((dynamic e) {
            return (e as Map<String, dynamic>)['message'] == 'shared message';
          }).length,
          equals(1),
        );
      },
    );

    test(
      '(i) non-duplicate crumbs entries are included in the response',
      () async {
        final DebugPrintCallback prior = debugPrint;
        addTearDown(() => debugPrint = prior);

        installLogCapture();
        addTearDown(uninstallLogCapture);

        debugPrint('from debugPrint');

        // Crumbs contributes a distinct entry.
        recentLogsReader = (ConsoleRequest request) => [
          <String, dynamic>{
            'level': 'WARNING',
            'message': 'from crumbs',
            'logger': 'my.logger',
            'time': '2024-01-01T00:00:00.000Z',
          },
        ];

        final response = await tapirConsoleHandler(
          'ext.tapir.console',
          <String, String>{},
        );

        final Map<String, dynamic> decoded =
            jsonDecode(response.result!) as Map<String, dynamic>;
        final List<dynamic> logs = decoded['logs'] as List<dynamic>;
        expect(logs, hasLength(2));
        // In-package entry comes first (newest-first, buffered before crumbs).
        expect(
          (logs.first as Map<String, dynamic>)['message'],
          equals('from debugPrint'),
        );
        expect(
          (logs.last as Map<String, dynamic>)['message'],
          equals('from crumbs'),
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // grep / logger filters and the capped marker
  // ---------------------------------------------------------------------------

  group('ext_console — grep and logger filters', () {
    setUp(() {
      recentLogsReader = (ConsoleRequest request) => const [];
      resetCapturedLogsForTesting();
    });

    tearDown(() {
      recentLogsReader = (ConsoleRequest request) => const [];
      resetCapturedLogsForTesting();
    });

    Future<Map<String, dynamic>> callConsole(Map<String, String> params) async {
      final response = await tapirConsoleHandler('ext.tapir.console', params);
      return jsonDecode(response.result!) as Map<String, dynamic>;
    }

    List<String> messages(Map<String, dynamic> decoded) =>
        (decoded['logs'] as List<dynamic>)
            .map(
              (dynamic e) => (e as Map<String, dynamic>)['message'] as String,
            )
            .toList();

    // A crumbs-shaped entry: a local ISO time without an offset. The default
    // year is newer than anything the in-package buffer records during a test;
    // pass an old year for an entry older than the buffer.
    Map<String, Object?> crumbEntry(
      String message,
      String logger, [
      int second = 0,
      int year = 2099,
    ]) => <String, Object?>{
      'level': 'INFO',
      'message': message,
      'logger': logger,
      'time': DateTime(
        year,
        1,
        1,
      ).add(Duration(seconds: second)).toIso8601String(),
    };

    // Like CrumbsStore.recentLogs: oldest first, and `limit` keeps the newest.
    List<Map<String, Object?>> Function(ConsoleRequest) oldestFirstReader(
      List<Map<String, Object?>> store,
    ) =>
        (ConsoleRequest request) => store.length > request.limit
        ? store.sublist(store.length - request.limit)
        : store;

    test('(j) a full debugPrint buffer no longer hides crumbs entries behind a '
        'logger or grep filter', () async {
      final DebugPrintCallback prior = debugPrint;
      addTearDown(() => debugPrint = prior);
      installLogCapture();
      addTearDown(uninstallLogCapture);

      for (int i = 0; i < 50; i++) {
        debugPrint('chatty line $i');
      }

      recentLogsReader = oldestFirstReader(<Map<String, Object?>>[
        crumbEntry('Legacy RARE-TOKEN sync', 'app.sync', 1, 2020),
        crumbEntry('checkout started', 'app', 2, 2020),
      ]);

      // Without a filter the 50 newer debugPrint lines fill the limit.
      expect(messages(await callConsole(<String, String>{})), hasLength(50));
      expect(
        messages(await callConsole(<String, String>{})),
        isNot(contains('checkout started')),
      );

      expect(
        messages(await callConsole(<String, String>{'logger': 'app'})),
        equals(<String>['checkout started']),
      );
      expect(
        messages(await callConsole(<String, String>{'grep': 'rare-token'})),
        equals(<String>['Legacy RARE-TOKEN sync']),
      );
    });

    test('(k) grep is a case-insensitive substring, logger is exact', () async {
      recentLogsReader = oldestFirstReader(<Map<String, Object?>>[
        crumbEntry('Payment FAILED', 'app.pay', 1),
        crumbEntry('payment ok', 'app.pay', 2),
        crumbEntry('payment failed again', 'app', 3),
      ]);

      expect(
        messages(await callConsole(<String, String>{'grep': 'failed'})),
        equals(<String>['payment failed again', 'Payment FAILED']),
      );
      expect(
        messages(await callConsole(<String, String>{'logger': 'app'})),
        equals(<String>['payment failed again']),
      );
      expect(
        messages(
          await callConsole(<String, String>{
            'logger': 'app.pay',
            'grep': 'FAILED',
          }),
        ),
        equals(<String>['Payment FAILED']),
      );
    });

    test('(l) filters apply before the limit clip', () async {
      recentLogsReader = oldestFirstReader(<Map<String, Object?>>[
        crumbEntry('needle older', 'app', 1),
        crumbEntry('noise 1', 'app', 2),
        crumbEntry('needle newer', 'app', 3),
        crumbEntry('noise 2', 'app', 4),
      ]);

      final Map<String, dynamic> decoded = await callConsole(<String, String>{
        'grep': 'needle',
        'limit': '1',
      });

      expect(messages(decoded), equals(<String>['needle newer']));
      expect(decoded['count'], equals(1));
    });

    test(
      '(m) a reader that clips to request.limit still yields every match',
      () async {
        // Oldest first: both targets sit behind 100 newer noise entries, so a
        // reader asked for the caller's limit of 10 would drop them.
        final List<Map<String, Object?>> store = <Map<String, Object?>>[
          crumbEntry('target one', 'app', 1),
          crumbEntry('target two', 'app', 2),
          for (int i = 0; i < 100; i++) crumbEntry('noise $i', 'app', 10 + i),
        ];
        final List<Map<String, Object?>> Function(ConsoleRequest) reader =
            oldestFirstReader(store);
        ConsoleRequest? seen;
        recentLogsReader = (ConsoleRequest request) {
          seen = request;
          return reader(request);
        };

        final Map<String, dynamic> decoded = await callConsole(<String, String>{
          'grep': 'target',
          'limit': '10',
        });

        expect(messages(decoded), equals(<String>['target two', 'target one']));
        expect(seen!.limit, greaterThan(store.length));
        expect(seen!.grep, equals('target'));
        expect(seen!.logger, isNull);
      },
    );

    test(
      '(s) a filtered limit keeps the newest matches across both sources',
      () async {
        final DebugPrintCallback prior = debugPrint;
        addTearDown(() => debugPrint = prior);
        installLogCapture();
        addTearDown(uninstallLogCapture);

        debugPrint('needle buffered');
        recentLogsReader = oldestFirstReader(<Map<String, Object?>>[
          crumbEntry('needle crumb A', 'app', 1),
          crumbEntry('noise', 'app', 2),
          crumbEntry('needle crumb B', 'app', 3),
          crumbEntry('needle crumb C', 'app', 4),
        ]);

        final Map<String, dynamic> decoded = await callConsole(<String, String>{
          'grep': 'needle',
          'limit': '2',
        });

        expect(
          messages(decoded),
          equals(<String>['needle crumb C', 'needle crumb B']),
        );
      },
    );

    test(
      '(t) an unfiltered merge is newest first by time across sources',
      () async {
        final DebugPrintCallback prior = debugPrint;
        addTearDown(() => debugPrint = prior);
        installLogCapture();
        addTearDown(uninstallLogCapture);

        debugPrint('buffered old');
        debugPrint('buffered new');
        recentLogsReader = oldestFirstReader(<Map<String, Object?>>[
          crumbEntry('crumb ancient', 'app', 1, 2020),
          crumbEntry('crumb recent', 'app', 2),
        ]);

        expect(
          messages(await callConsole(<String, String>{})),
          equals(<String>[
            'crumb recent',
            'buffered new',
            'buffered old',
            'crumb ancient',
          ]),
        );
      },
    );

    test('(v) a repeated crumbs entry keeps its newest occurrence', () async {
      recentLogsReader = oldestFirstReader(<Map<String, Object?>>[
        crumbEntry('repeat', 'app', 1),
        crumbEntry('other', 'app', 2),
        crumbEntry('repeat', 'app', 3),
      ]);
      final Object? newest = crumbEntry('repeat', 'app', 3)['time'];

      for (final Map<String, String> params in <Map<String, String>>[
        <String, String>{'logger': 'app', 'limit': '1'},
        <String, String>{'limit': '1'},
      ]) {
        final Map<String, dynamic> decoded = await callConsole(params);
        final Map<String, dynamic> first =
            (decoded['logs'] as List<dynamic>).single as Map<String, dynamic>;
        expect(first['message'], equals('repeat'));
        expect(first['time'], equals(newest));
      }
    });

    test('(w) a cross-source duplicate keeps the buffered entry', () async {
      final DebugPrintCallback prior = debugPrint;
      addTearDown(() => debugPrint = prior);
      installLogCapture();
      addTearDown(uninstallLogCapture);

      debugPrint('shared line');
      recentLogsReader = oldestFirstReader(<Map<String, Object?>>[
        crumbEntry('shared line', 'debugPrint', 1),
      ]);

      final Map<String, dynamic> decoded = await callConsole(<String, String>{
        'logger': 'debugPrint',
      });

      final List<dynamic> logs = decoded['logs'] as List<dynamic>;
      expect(logs, hasLength(1));
      // The buffer stamps UTC ('Z'); the crumbs fake stamps local time.
      expect(
        ((logs.single as Map<String, dynamic>)['time'] as String).endsWith('Z'),
        isTrue,
      );
    });

    test(
      '(u) entries without a parseable time follow the dated ones',
      () async {
        recentLogsReader = (ConsoleRequest request) => <Map<String, Object?>>[
          <String, Object?>{
            'level': 'INFO',
            'message': 'no time',
            'logger': 'app',
          },
          crumbEntry('dated old', 'app', 1),
          <String, Object?>{
            'level': 'INFO',
            'message': 'bad time',
            'logger': 'app',
            'time': 'not a time',
          },
          crumbEntry('dated new', 'app', 2),
        ];

        expect(
          messages(await callConsole(<String, String>{})),
          equals(<String>['dated new', 'dated old', 'no time', 'bad time']),
        );
      },
    );

    test('(n) without a filter the reader gets the caller limit', () async {
      ConsoleRequest? seen;
      recentLogsReader = (ConsoleRequest request) {
        seen = request;
        return const [];
      };

      await callConsole(<String, String>{'limit': '7'});

      expect(seen!.limit, equals(7));
      expect(seen!.grep, isNull);
      expect(seen!.logger, isNull);
    });

    test('(o) an empty grep or logger param means no filter', () async {
      ConsoleRequest? seen;
      recentLogsReader = (ConsoleRequest request) {
        seen = request;
        return <Map<String, Object?>>[crumbEntry('kept', 'app')];
      };

      final Map<String, dynamic> decoded = await callConsole(<String, String>{
        'grep': '',
        'logger': '',
      });

      expect(messages(decoded), equals(<String>['kept']));
      expect(seen!.limit, equals(50));
      expect(seen!.grep, isNull);
      expect(seen!.logger, isNull);
    });
  });

  group('ext_console — capped marker', () {
    setUp(() {
      recentLogsReader = (ConsoleRequest request) => const [];
      resetCapturedLogsForTesting();
    });

    tearDown(resetCapturedLogsForTesting);

    test('(p) capped is absent while the buffer has not evicted', () async {
      final DebugPrintCallback prior = debugPrint;
      addTearDown(() => debugPrint = prior);
      installLogCapture();
      addTearDown(uninstallLogCapture);

      for (int i = 0; i < 50; i++) {
        debugPrint('line $i');
      }

      final response = await tapirConsoleHandler(
        'ext.tapir.console',
        <String, String>{},
      );
      final Map<String, dynamic> decoded =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(decoded.containsKey('capped'), isFalse);
    });

    test('(q) capped is true once the buffer evicted older lines', () async {
      final DebugPrintCallback prior = debugPrint;
      addTearDown(() => debugPrint = prior);
      installLogCapture();
      addTearDown(uninstallLogCapture);

      for (int i = 0; i < 51; i++) {
        debugPrint('line $i');
      }

      final response = await tapirConsoleHandler(
        'ext.tapir.console',
        <String, String>{'limit': '200'},
      );
      final Map<String, dynamic> decoded =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(decoded['capped'], isTrue);
      expect(decoded['count'], equals(50));
    });

    test('(r) capped clears with the buffer reset', () async {
      final DebugPrintCallback prior = debugPrint;
      addTearDown(() => debugPrint = prior);
      installLogCapture();

      for (int i = 0; i < 51; i++) {
        debugPrint('line $i');
      }
      resetCapturedLogsForTesting();

      final response = await tapirConsoleHandler(
        'ext.tapir.console',
        <String, String>{},
      );
      final Map<String, dynamic> decoded =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(decoded.containsKey('capped'), isFalse);
    });
  });

  group('ext_console — MCP descriptor presence', () {
    test('tapir_console MCP descriptor name is "tapir_console"', () {
      expect(kTapirConsoleMcpName, equals('tapir_console'));
    });

    test(
      'tapir_console MCP descriptor extensionMethod is ext.tapir.console',
      () {
        expect(kTapirConsoleMcpExtension, equals('ext.tapir.console'));
      },
    );
  });
}
