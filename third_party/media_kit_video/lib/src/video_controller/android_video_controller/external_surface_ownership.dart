/// PiliPlus patch: pure, dependency-free state machine for Android video
/// output surface ownership -- whether libmpv's `--wid` currently belongs
/// to the internal Flutter texture or to an externally-owned Android
/// Surface (e.g. a native PiP shell's TextureView).
///
/// This file intentionally has zero Flutter/FFI/platform-channel
/// dependencies so the ownership bookkeeping can be unit tested offline.
/// [AndroidVideoController] owns the actual `player.setOption(...)` calls
/// and platform-channel plumbing; it asks this class "what should happen
/// now" and applies the answer.
library;

/// Tracks whether the output currently belongs to an externally-owned
/// surface, and whether a media reload is currently pending re-attachment
/// of that external surface once the reload completes.
///
/// Lifecycle summary:
/// - [attach]: an external surface takes (or re-asserts) ownership.
/// - [onUnload]: libmpv is about to tear down `vo`/`wid` for a reload;
///   if external ownership is active, mark it so the next load/videoParams
///   event re-attaches the external surface instead of stealing the output
///   back to the internal surface.
/// - [consumeReattachIfNeeded]: called from `onLoadHooks`/`videoParams`
///   once a fresh surface/media is ready; tells the caller whether to
///   (re)apply the external surface now.
/// - [detach]: external ownership is given up (PiP expanded, or a new page
///   takes over the player) and the internal surface should become the
///   output again. Returns whether a reload was in flight, in which case
///   the caller should let the load hook finish the internal attach on its
///   own instead of racing it with a possibly-stale internal `wid`.
/// - [release]: external ownership is dropped without any restore-to-
///   internal semantics (the external surface itself was destroyed, or the
///   player is being disposed).
class ExternalSurfaceOwnership {
  bool _active = false;
  String? _wid;
  int _width = 0;
  int _height = 0;
  bool _reattachPending = false;

  /// Whether the output is currently owned by an external surface.
  bool get active => _active;

  /// The external surface's `wid` (JNI global-ref, decimal string), or
  /// `null` if not currently attached.
  String? get wid => _wid;

  /// Last known width/height of the attached external surface (0 if none).
  int get width => _width;
  int get height => _height;

  /// Whether a reload is currently in flight and the external surface
  /// still needs to be re-attached once it completes.
  bool get reattachPending => _reattachPending;

  /// An external surface takes (or re-asserts, e.g. after a reload)
  /// ownership of the output. Always leaves [reattachPending] cleared --
  /// the caller is expected to immediately apply the surface.
  void attach(String wid, int width, int height) {
    _active = true;
    _wid = wid;
    _width = width;
    _height = height;
    _reattachPending = false;
  }

  /// The externally-owned surface was resized (e.g. native PiP window
  /// resize). Returns `true` if the caller should push the new size to the
  /// player immediately; `false` if there's nothing to do (not active, or
  /// a reattach is already pending and will pick up the latest size on its
  /// own once it fires).
  bool updateSize(int width, int height) {
    if (!_active) {
      return false;
    }
    _width = width;
    _height = height;
    return !_reattachPending;
  }

  /// Called from `onUnloadHooks`, where libmpv's `vo`/`wid` are always
  /// torn down. Returns `true` if external ownership survives the reload
  /// (i.e. [reattachPending] is now set and the caller must re-attach it
  /// once the reload completes) -- `false` if there's no external surface
  /// to preserve.
  bool onUnload() {
    if (_active) {
      _reattachPending = true;
      return true;
    }
    return false;
  }

  /// Called once a fresh surface/media is ready (`onLoadHooks` after a new
  /// `CreateSurface`, or the first `videoParams` event of a reload).
  /// Returns `true` if the caller should (re)apply the external surface
  /// right now; always clears [reattachPending] as a side effect when
  /// active.
  bool consumeReattachIfNeeded() {
    if (_active) {
      _reattachPending = false;
      return true;
    }
    return false;
  }

  /// Give up external ownership and hand the output back to the internal
  /// surface (PiP expand, or a new page taking over the player).
  ///
  /// Returns `true` if a reload was in flight at the moment of detaching:
  /// in that case the caller should NOT attempt to restore the internal
  /// surface itself (it may be stale/not-yet-recreated) and should instead
  /// let the in-flight `onLoadHooks`/`videoParams` complete the internal
  /// attach on its own now that [active] is `false`. Returns `false` if no
  /// reload was in flight, meaning the caller is responsible for restoring
  /// the internal surface immediately (and should treat inability to do so
  /// -- e.g. no internal `wid` yet -- as its own fallback case).
  bool detach() {
    if (!_active) {
      return false;
    }
    final reloadInFlight = _reattachPending;
    _active = false;
    _wid = null;
    _width = 0;
    _height = 0;
    _reattachPending = false;
    return reloadInFlight;
  }

  /// Drop external ownership without any restore-to-internal semantics --
  /// used when the external surface itself is being destroyed (caller
  /// already tore down `vo`/`wid` if it was still pointed at it) or the
  /// player is about to be disposed.
  void release() {
    _active = false;
    _wid = null;
    _width = 0;
    _height = 0;
    _reattachPending = false;
  }
}

/// A tiny monotonic generation/epoch counter used to detect and invalidate
/// stale async callbacks -- e.g. an `await`-ed `CreateSurface` platform
/// channel call that resolves after a newer load (or a dispose) has
/// already superseded it.
class LoadGeneration {
  int _value = 0;
  bool _disposed = false;

  /// Advance to a new generation and return its token. Callers should
  /// capture the returned token before an `await` and re-check it with
  /// [isCurrent] afterwards.
  int next() => ++_value;

  /// Whether [token] (previously returned by [next]) is still the current
  /// generation, i.e. no newer [next] call and no [dispose] happened while
  /// the caller was awaiting something.
  bool isCurrent(int token) => !_disposed && token == _value;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Marks this generation source as disposed: every previously-issued
  /// token (and any future one, until a hypothetical un-dispose which this
  /// class doesn't support) is considered stale.
  void dispose() {
    _disposed = true;
    _value++;
  }
}
