import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tapir/src/extensions/ext_modal_router.dart';

void main() {
  // NOTE: dismissAllModals awaits no frame for a modal that leaves inside its
  // pop, so plain modals can be dismissed here with a bare await. A modal that
  // guards its exit is given frames to leave, so those tests drive the call
  // through _dismissPumping. Tests that open a modal must call tester.pump()
  // after dismissAllModals() to settle the widget tree.

  group('dismissAllModals helper', () {
    testWidgets('returns 0 when binding root is unset', (tester) async {
      // Pumping no widget leaves rootElement null in some test paths;
      // dismissAllModals must short-circuit safely.
      final dismissed = await dismissAllModals();
      expect(dismissed, equals(0));
    });

    testWidgets('returns 0 when no Navigator exists in the tree', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Text('No nav'),
        ),
      );
      final dismissed = await dismissAllModals();
      expect(dismissed, equals(0));
    });

    testWidgets(
      'dismisses a showModalBottomSheet on the nearest navigator (popped==1)',
      (tester) async {
        // 1. Pump a minimal MaterialApp so there is a Navigator + Overlay.
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const SizedBox(
                      height: 200,
                      child: Center(child: Text('sheet')),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

        // 2. Open the bottom sheet (nearest navigator, useRootNavigator: false).
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('sheet'), findsOneWidget);

        // 3. Dismiss via the extension under test.
        final popped = await dismissAllModals();
        // pumpAndSettle lets the route exit animation finish and the route
        // entry be removed from the overlay. The sheet uses Duration.zero-ish
        // transitions in test mode but still needs at least one frame.
        await tester.pumpAndSettle();

        // 4. The sheet must be gone and exactly one route was popped.
        expect(popped, equals(1));
        expect(find.text('sheet'), findsNothing);
      },
    );

    testWidgets('dismisses two stacked PopupRoutes on the same navigator; '
        'returns additive total (popped==2)', (tester) async {
      // Reproduce the multi-modal count bug: an early implementation only
      // popped one PopupRoute per call. Every PopupRoute on the navigator
      // must go in one call.
      //
      // showDialog defaults useRootNavigator: true and showModalBottomSheet
      // defaults useRootNavigator: false. In a single-navigator app both
      // land on the same navigator. We open both and verify popped==2.

      // 1. Capture the Scaffold context via a GlobalKey so we can call
      //    showDialog / showModalBottomSheet after pumpWidget returns.
      final scaffoldKey = GlobalKey<ScaffoldState>();
      late NavigatorState nav;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              nav = Navigator.of(context);
              return Scaffold(key: scaffoldKey, body: const Text('home'));
            },
          ),
        ),
      );
      await tester.pump();

      // Resolve a context that is inside the MaterialApp so Material
      // Localizations and Navigator are available.
      final BuildContext ctx = tester.element(find.byKey(scaffoldKey));

      // 2. Push dialog (PopupRoute via showDialog -> RawDialogRoute).
      showDialog<void>(
        context: ctx,
        builder: (_) => const AlertDialog(title: Text('dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.text('dialog'), findsOneWidget);

      // 3. Push bottom sheet on top of the dialog (second PopupRoute).
      showModalBottomSheet<void>(
        context: ctx,
        builder: (_) =>
            const SizedBox(height: 200, child: Center(child: Text('sheet'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('sheet'), findsOneWidget);

      // 4. Dismiss all modals. Both PopupRoutes must be removed.
      final popped = await dismissAllModals();
      await tester.pumpAndSettle();

      expect(popped, equals(2));
      expect(find.text('sheet'), findsNothing);
      expect(find.text('dialog'), findsNothing);

      // Home page must still be present (page route was NOT popped).
      expect(find.text('home'), findsOneWidget);
      expect(nav.canPop(), isFalse);
    });
  });

  group('dismissAllModals over a route that guards its own exit', () {
    /// Mounts a one-page app and answers its root Navigator.
    Future<NavigatorState> mountHome(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );

      return tester.state<NavigatorState>(find.byType(Navigator));
    }

    /// Pushes [route] on [navigator] and lets it land.
    Future<void> open(
      WidgetTester tester,
      NavigatorState navigator,
      Route<void> route,
    ) async {
      unawaited(navigator.push(route));
      await tester.pumpAndSettle();
    }

    testWidgets('an exit the guard allows is dismissed and counted', (
      tester,
    ) async {
      final NavigatorState navigator = await mountHome(tester);
      final _FakeModalRoute sheet = _FakeModalRoute(
        label: 'guarded-sheet',
        guard: _ExitGuard.allow,
      );
      await open(tester, navigator, sheet);

      final int popped = await _dismissPumping(tester);
      await tester.pumpAndSettle();

      expect(popped, equals(1));
      expect(sheet.isActive, isFalse);
      expect(find.text('guarded-sheet'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('an exit the guard refuses leaves the modal open, uncounted', (
      tester,
    ) async {
      final NavigatorState navigator = await mountHome(tester);
      final _FakeModalRoute sheet = _FakeModalRoute(
        label: 'refusing-sheet',
        guard: _ExitGuard.refuse,
      );
      await open(tester, navigator, sheet);

      final int popped = await _dismissPumping(tester);
      await tester.pumpAndSettle();

      expect(popped, equals(0));
      expect(sheet.isCurrent, isTrue);
      expect(sheet.popRequests, equals(1), reason: 'one pop, never retried');
      expect(find.text('refusing-sheet'), findsOneWidget);
    });

    testWidgets('a plain modal above a refusing one is dismissed; the refusing '
        'one stays', (tester) async {
      final NavigatorState navigator = await mountHome(tester);
      final _FakeModalRoute refusing = _FakeModalRoute(
        label: 'refusing-sheet',
        guard: _ExitGuard.refuse,
      );
      final _FakeModalRoute plain = _FakeModalRoute(label: 'plain-dialog');
      await open(tester, navigator, refusing);
      await open(tester, navigator, plain);

      final int popped = await _dismissPumping(tester);
      await tester.pumpAndSettle();

      expect(popped, equals(1));
      expect(plain.isActive, isFalse);
      expect(refusing.isCurrent, isTrue);
    });

    testWidgets('dismissal carries on below a modal whose guard allows exit', (
      tester,
    ) async {
      final NavigatorState navigator = await mountHome(tester);
      final _FakeModalRoute plain = _FakeModalRoute(label: 'plain-dialog');
      final _FakeModalRoute guarded = _FakeModalRoute(
        label: 'guarded-sheet',
        guard: _ExitGuard.allow,
      );
      await open(tester, navigator, plain);
      await open(tester, navigator, guarded);

      final int popped = await _dismissPumping(tester);
      await tester.pumpAndSettle();

      expect(popped, equals(2));
      expect(guarded.isActive, isFalse);
      expect(plain.isActive, isFalse);
      expect(navigator.canPop(), isFalse);
    });

    testWidgets('nested navigators are still cleared innermost first', (
      tester,
    ) async {
      final GlobalKey<NavigatorState> innerKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            key: innerKey,
            onGenerateRoute: (RouteSettings settings) =>
                MaterialPageRoute<void>(
                  builder: (BuildContext context) => const Text('inner-home'),
                ),
          ),
        ),
      );
      final NavigatorState root = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      final List<String> dismissed = <String>[];
      await open(
        tester,
        root,
        _FakeModalRoute(label: 'outer-modal', popLog: dismissed),
      );
      await open(
        tester,
        innerKey.currentState!,
        _FakeModalRoute(label: 'inner-modal', popLog: dismissed),
      );

      final int popped = await _dismissPumping(tester);
      await tester.pumpAndSettle();

      expect(popped, equals(2));
      expect(dismissed, equals(<String>['inner-modal', 'outer-modal']));
    });
  });

  group('registerModalRouterExtension', () {
    test('runs without throwing twice in a row (hot-restart safe)', () {
      registerModalRouterExtension();
      registerModalRouterExtension();
    });
  });

  group('tapirResetOverlaysHandler', () {
    testWidgets('its Escape reaches the focused widget, as a real press does', (
      tester,
    ) async {
      final List<LogicalKeyboardKey> heard = <LogicalKeyboardKey>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Focus(
            autofocus: true,
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is KeyDownEvent) heard.add(event.logicalKey);

              return KeyEventResult.handled;
            },
            child: const Text('idle'),
          ),
        ),
      );

      await tester.runAsync(
        () => tapirResetOverlaysHandler(
          'ext.tapir.reset_overlays',
          const <String, String>{},
        ),
      );

      expect(heard, <LogicalKeyboardKey>[LogicalKeyboardKey.escape]);
    });

    testWidgets(
      'with no key data handler the Escape layer reports escaped=false '
      'and the reset still succeeds',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: Text('idle'))),
        );
        final dispatcher = tester.binding.platformDispatcher;
        final saved = dispatcher.onKeyData;
        dispatcher.onKeyData = null;
        addTearDown(() => dispatcher.onKeyData = saved);

        final response = await tester.runAsync(
          () => tapirResetOverlaysHandler(
            'ext.tapir.reset_overlays',
            const <String, String>{},
          ),
        );

        expect(response!.errorCode, isNull);
        final Map<String, dynamic> json =
            jsonDecode(response.result!) as Map<String, dynamic>;
        expect(json['escaped'], isFalse);
      },
    );

    testWidgets('idempotent: returns popped=0 when no overlays are open', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('idle'))),
      );

      // First call: nothing to dismiss. runAsync drives the handler's
      // endOfFrame.timeout settle steps against a real clock.
      final first = await tester.runAsync(() async {
        return tapirResetOverlaysHandler(
          'ext.tapir.reset_overlays',
          const <String, String>{},
        );
      });
      expect(first!.errorCode, isNull);
      final Map<String, dynamic> firstJson =
          jsonDecode(first.result!) as Map<String, dynamic>;
      expect(firstJson['popped'], equals(0));

      // Second call on the same idle tree: identical result (idempotent).
      final second = await tester.runAsync(() async {
        return tapirResetOverlaysHandler(
          'ext.tapir.reset_overlays',
          const <String, String>{},
        );
      });
      expect(second!.errorCode, isNull);
      final Map<String, dynamic> secondJson =
          jsonDecode(second.result!) as Map<String, dynamic>;
      expect(secondJson['popped'], equals(0));
    });

    testWidgets('dismisses an open bottom sheet and reports popped>=1', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => const SizedBox(
                    height: 150,
                    child: Center(child: Text('reset-sheet')),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('reset-sheet'), findsOneWidget);

      final response = await tester.runAsync(() async {
        return tapirResetOverlaysHandler(
          'ext.tapir.reset_overlays',
          const <String, String>{},
        );
      });
      await tester.pumpAndSettle();

      expect(response!.errorCode, isNull);
      final Map<String, dynamic> json =
          jsonDecode(response.result!) as Map<String, dynamic>;
      expect(json['popped'], equals(1));
      expect(find.text('reset-sheet'), findsNothing);

      // Calling again on the now-clean tree is a no-op (idempotent).
      final again = await tester.runAsync(() async {
        return tapirResetOverlaysHandler(
          'ext.tapir.reset_overlays',
          const <String, String>{},
        );
      });
      final Map<String, dynamic> againJson =
          jsonDecode(again!.result!) as Map<String, dynamic>;
      expect(againJson['popped'], equals(0));
    });
  });

  group('isModalRoute', () {
    test('returns true for a PopupRoute subclass', () {
      expect(isModalRoute(_TestPopupRoute<void>()), isTrue);
    });

    test('returns false for a MaterialPageRoute (regular page route)', () {
      final page = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      expect(isModalRoute(page), isFalse);
    });
  });

  group('tapirDismissModalsHandler envelope', () {
    testWidgets('returns popped=0 when no modals are open', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('idle'))),
      );

      final response = await tapirDismissModalsHandler(
        'ext.tapir.dismiss_modals',
        const <String, String>{},
      );
      expect(response.errorCode, isNull);
      expect(response.result, contains('"popped":0'));
    });

    testWidgets(
      'no modals + navigator present → popUntil short-circuits on page route',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            routes: <String, WidgetBuilder>{
              '/': (_) => const Scaffold(body: Text('home')),
              '/second': (_) => const Scaffold(body: Text('second')),
            },
          ),
        );

        // Push a regular page route so canPop() is true but the top route
        // is NOT a PopupRoute — exercises the popUntil stop condition.
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.pushNamed('/second');
        await tester.pumpAndSettle();
        expect(navigator.canPop(), isTrue);

        final response = await tapirDismissModalsHandler(
          'ext.tapir.dismiss_modals',
          const <String, String>{},
        );
        expect(response.errorCode, isNull);
        expect(response.result, contains('"popped":0'));
      },
    );

    testWidgets('handler returns popped==1 when a bottom sheet is open', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => const SizedBox(
                    height: 150,
                    child: Center(child: Text('handler-sheet')),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('handler-sheet'), findsOneWidget);

      final response = await tapirDismissModalsHandler(
        'ext.tapir.dismiss_modals',
        const <String, String>{},
      );
      await tester.pumpAndSettle();

      expect(response.errorCode, isNull);
      expect(response.result, contains('"popped":1'));
      expect(find.text('handler-sheet'), findsNothing);
    });
  });
}

/// Runs [dismissAllModals] while pumping frames, so its frame waits resolve
/// under the fake clock, and fails instead of hanging when it never returns.
Future<int> _dismissPumping(WidgetTester tester) async {
  int? popped;
  Object? failure;
  unawaited(
    dismissAllModals().then(
      (int value) => popped = value,
      onError: (Object error) => failure = error,
    ),
  );
  for (int frame = 0; frame < 40; frame++) {
    if (popped != null || failure != null) break;
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (failure != null) throw failure!;
  expect(popped, isNotNull, reason: 'dismissAllModals did not return');

  return popped!;
}

/// How a [_FakeModalRoute] answers a pop.
enum _ExitGuard {
  /// No guard: the pop lands at once, as a plain dialog's does.
  none,

  /// The pop is refused, then the exit lands on the next frame.
  allow,

  /// The pop is refused and the modal stays.
  refuse,
}

/// A modal whose guarded pop behaves the way go_router 18 treats a page whose
/// `GoRoute` has `onExit`: `GoRouterDelegate._handlePopPageWithRouteMatch`
/// refuses the pop synchronously, runs `onExit` in a `scheduleMicrotask`, and
/// an exit it allows leaves the Navigator only when the Router rebuilds the
/// page list on the next frame.
///
/// go_router is not a dev dependency, and its refusal reaches the Navigator
/// through the deprecated `onPopPage`, so the refusal sits in [didPop]
/// instead: [NavigatorState.pop] keeps the route current either way. A pop
/// refused more than a handful of times throws, so a dismiss loop that never
/// lets the exit land fails the test rather than freezing the runner.
final class _FakeModalRoute extends PopupRoute<void> {
  _FakeModalRoute({
    required this.label,
    this.guard = _ExitGuard.none,
    this.popLog,
  });

  final String label;

  final _ExitGuard guard;

  /// Receives [label] when a pop of this route is requested.
  final List<String>? popLog;

  /// How many times a pop of this route has been requested.
  int popRequests = 0;

  @override
  bool didPop(void result) {
    popRequests++;
    popLog?.add(label);
    if (guard == _ExitGuard.none) return super.didPop(result);

    if (popRequests > 5) {
      throw StateError(
        'pop of "$label" refused $popRequests times in a row: the dismiss '
        'loop is spinning over a pop that did not advance',
      );
    }
    scheduleMicrotask(() {
      if (guard == _ExitGuard.refuse) return;
      SchedulerBinding.instance.addPostFrameCallback((Duration _) {
        if (isActive) navigator!.removeRoute(this);
      });
      SchedulerBinding.instance.scheduleFrame();
    });

    return false;
  }

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Center(child: Text(label));
}

class _TestPopupRoute<T> extends PopupRoute<T> {
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox.shrink();
}
