// Offline unit tests for the pure Android video-output surface ownership
// state machine used by AndroidVideoController to keep a native PiP shell
// (or any other external Surface consumer) from freezing on media reload.
//
// These tests exercise the same scenarios called out in the PiP surface
// stability fix: normal internal-only playback, entering PiP, an
// unload/load cycle while in PiP, several back-to-back reloads while in
// PiP, stale/superseded async callbacks, PiP expand, PiP close, a new
// video page taking over the player mid-PiP, and the external surface
// itself being destroyed.
import 'package:media_kit_video/src/video_controller/android_video_controller/external_surface_ownership.dart';
import 'package:test/test.dart';

void main() {
  group('ExternalSurfaceOwnership', () {
    test('starts inactive: normal Flutter-surface-only playback', () {
      final o = ExternalSurfaceOwnership();
      expect(o.active, isFalse);
      expect(o.wid, isNull);
      expect(o.width, 0);
      expect(o.height, 0);
      expect(o.reattachPending, isFalse);

      // Nothing to preserve across an unload/load cycle when nobody has
      // taken external ownership.
      expect(o.onUnload(), isFalse);
      expect(o.consumeReattachIfNeeded(), isFalse);
      // Resize/detach/release on an inactive machine are all safe no-ops.
      expect(o.updateSize(1920, 1080), isFalse);
      expect(o.detach(), isFalse);
      o.release();
      expect(o.active, isFalse);
    });

    test('attach hands ownership to the external (PiP) surface', () {
      final o = ExternalSurfaceOwnership();
      o.attach('123', 1280, 720);
      expect(o.active, isTrue);
      expect(o.wid, '123');
      expect(o.width, 1280);
      expect(o.height, 720);
      expect(o.reattachPending, isFalse);
    });

    test('unload while external-active marks reattachPending and survives '
        'the reload; load/videoParams consumes it exactly once', () {
      final o = ExternalSurfaceOwnership();
      o.attach('123', 1280, 720);

      // onUnloadHooks: libmpv tears down vo/wid for the reload.
      expect(o.onUnload(), isTrue);
      expect(o.active, isTrue, reason: 'ownership itself is preserved');
      expect(o.reattachPending, isTrue);

      // While reattach is pending, a size update should NOT be pushed to
      // the player immediately (nothing is attached to render into yet);
      // the eventual reattach picks up the latest size on its own.
      expect(o.updateSize(1920, 1080), isFalse);
      expect(o.width, 1920);
      expect(o.height, 1080);

      // onLoadHooks / first videoParams of the new media: re-attach.
      expect(o.consumeReattachIfNeeded(), isTrue);
      expect(o.reattachPending, isFalse);
      // A second call (e.g. videoParams firing again) should not
      // re-trigger unnecessary reattachment logic beyond "still active".
      expect(o.consumeReattachIfNeeded(), isTrue);
    });

    test('multiple consecutive reloads while in PiP stay idempotent', () {
      final o = ExternalSurfaceOwnership();
      o.attach('1', 100, 100);

      for (var i = 0; i < 5; i++) {
        expect(o.onUnload(), isTrue);
        expect(o.reattachPending, isTrue);
        expect(o.consumeReattachIfNeeded(), isTrue);
        expect(o.reattachPending, isFalse);
        expect(o.active, isTrue);
      }
    });

    test('detach mid-reload defers restore to the in-flight load', () {
      final o = ExternalSurfaceOwnership();
      o.attach('1', 100, 100);
      o.onUnload(); // reload starts, reattach now pending

      // User expands PiP while the reload is still mid-flight.
      final reloadInFlight = o.detach();
      expect(reloadInFlight, isTrue);
      expect(o.active, isFalse);
      expect(o.reattachPending, isFalse);
      expect(o.wid, isNull);

      // The in-flight load must not think it should re-apply an external
      // surface anymore.
      expect(o.consumeReattachIfNeeded(), isFalse);
    });

    test('detach with no reload in flight reports nothing pending', () {
      final o = ExternalSurfaceOwnership();
      o.attach('1', 100, 100);

      final reloadInFlight = o.detach();
      expect(reloadInFlight, isFalse);
      expect(o.active, isFalse);
    });

    test('detach when never attached is a no-op reporting no reload', () {
      final o = ExternalSurfaceOwnership();
      expect(o.detach(), isFalse);
      expect(o.active, isFalse);
    });

    test('release (PiP close / surface destroyed) drops ownership state', () {
      final o = ExternalSurfaceOwnership();
      o.attach('1', 100, 100);
      o.onUnload();
      expect(o.reattachPending, isTrue);

      o.release();
      expect(o.active, isFalse);
      expect(o.wid, isNull);
      expect(o.reattachPending, isFalse);

      // A stale reattach check after release must not resurrect ownership.
      expect(o.consumeReattachIfNeeded(), isFalse);
    });

    test('new video page takeover behaves like detach (hide())', () {
      final o = ExternalSurfaceOwnership();
      o.attach('1', 100, 100);

      // getInstance()/hide() detaches exactly like PiP expand.
      final reloadInFlight = o.detach();
      expect(reloadInFlight, isFalse);
      expect(o.active, isFalse);
    });

    test('updateSize while active and not pending applies immediately', () {
      final o = ExternalSurfaceOwnership();
      o.attach('1', 100, 100);
      expect(o.updateSize(200, 300), isTrue);
      expect(o.width, 200);
      expect(o.height, 300);
    });

    test('re-attach after detach starts a fresh ownership cycle', () {
      final o = ExternalSurfaceOwnership();
      o.attach('1', 100, 100);
      o.detach();
      expect(o.active, isFalse);

      // A second PiP session (new wid from a fresh native surface).
      o.attach('2', 400, 300);
      expect(o.active, isTrue);
      expect(o.wid, '2');
      expect(o.width, 400);
      expect(o.height, 300);
    });
  });

  group('LoadGeneration', () {
    test('fresh generation tokens are current until superseded', () {
      final g = LoadGeneration();
      final t1 = g.next();
      expect(g.isCurrent(t1), isTrue);
    });

    test('a newer generation invalidates the previous (stale callback)', () {
      final g = LoadGeneration();
      final t1 = g.next(); // e.g. quality switch #1 starts CreateSurface
      final t2 = g.next(); // quality switch #2 starts before #1 resolves
      expect(g.isCurrent(t1), isFalse, reason: 'stale callback #1');
      expect(g.isCurrent(t2), isTrue);
    });

    test('dispose invalidates every outstanding token', () {
      final g = LoadGeneration();
      final t1 = g.next();
      expect(g.isDisposed, isFalse);
      g.dispose();
      expect(g.isDisposed, isTrue);
      expect(g.isCurrent(t1), isFalse);

      // Even a freshly-issued token after dispose isn't "current" because
      // isCurrent() unconditionally treats a disposed source as stale.
      final t2 = g.next();
      expect(g.isCurrent(t2), isFalse);
    });
  });
}
