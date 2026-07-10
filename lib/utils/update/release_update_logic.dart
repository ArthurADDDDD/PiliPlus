/// Pure, offline-testable logic for the fork's self-update mechanism.
///
/// Nothing in this file touches Flutter UI, `dart:io`, networking, or any
/// global/static app state -- it only parses inputs (a GitHub Release JSON
/// map, a release tag string, a list of supported Android ABIs) and returns
/// plain data/decisions. `lib/utils/update.dart` is the thin, impure layer
/// that fetches the release, calls into here, and drives the UI.
library;

// ---------------------------------------------------------------------------
// Version / tag parsing
// ---------------------------------------------------------------------------

/// A parsed `<name>+<buildNumber>` version identifier, as used by both
/// `pubspec.yaml`'s `version:` field (e.g. `2.0.9+5103`) and formal release
/// tags (`v2.0.9+5103`, optionally without the leading `v`).
///
/// [buildNumber] is the sole signal used for "is this newer" comparisons
/// (it maps 1:1 to Android's `versionCode` / Flutter's build number, which
/// is guaranteed to be an integer and is what the CI release preflight
/// enforces matches `pubspec.yaml`). [name] is display-only.
class ReleaseVersion {
  final String name;
  final int buildNumber;

  const ReleaseVersion(this.name, this.buildNumber);

  static final RegExp _pattern = RegExp(r'^[vV]?(.+)\+(\d+)$');

  /// Parses `v2.0.9+5103` or `2.0.9+5103`. Returns `null` if [input] is
  /// null/empty/whitespace-only, or isn't in `[v]<name>+<integer>` form
  /// (e.g. a bare upstream-style tag like `v2.0.9` with no build number,
  /// or garbage). Callers should treat a `null` result as "this tag can't
  /// be trusted for version comparison" and fall back accordingly -- see
  /// [decideShouldPromptUpdate].
  static ReleaseVersion? tryParse(String? input) {
    if (input == null) return null;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final match = _pattern.firstMatch(trimmed);
    if (match == null) return null;
    final name = match.group(1)!;
    if (name.isEmpty) return null;
    final buildNumber = int.tryParse(match.group(2)!);
    if (buildNumber == null) return null;
    return ReleaseVersion(name, buildNumber);
  }

  @override
  String toString() => '$name+$buildNumber';

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion &&
      other.name == name &&
      other.buildNumber == buildNumber;

  @override
  int get hashCode => Object.hash(name, buildNumber);
}

// ---------------------------------------------------------------------------
// GitHub "latest release" response parsing
// ---------------------------------------------------------------------------

/// One downloadable file attached to a GitHub Release.
class ReleaseAsset {
  final String name;
  final String downloadUrl;

  const ReleaseAsset({required this.name, required this.downloadUrl});
}

/// Outcome of asking GitHub for `GET /repos/<owner>/<repo>/releases/latest`.
sealed class LatestReleaseResult {
  const LatestReleaseResult();
}

/// A usable, non-draft, (by default) non-prerelease release was found.
final class LatestReleaseFound extends LatestReleaseResult {
  final String tagName;
  final String? name;
  final String? body;
  final String? publishedAt;
  final String? createdAt;
  final String? htmlUrl;
  final List<ReleaseAsset> assets;
  final bool prerelease;

  const LatestReleaseFound({
    required this.tagName,
    this.name,
    this.body,
    this.publishedAt,
    this.createdAt,
    this.htmlUrl,
    this.assets = const [],
    this.prerelease = false,
  });
}

/// The repo has no (matching) formal release yet -- GitHub 404s
/// `/releases/latest` when there are zero releases, and this is also used
/// for a release that was found but filtered out (draft, or prerelease
/// while prereleases aren't opted into). Not an error: a fork that simply
/// hasn't published anything yet is an entirely expected, common state.
final class LatestReleaseNotFound extends LatestReleaseResult {
  const LatestReleaseNotFound();
}

/// Something about the response couldn't be trusted: a transport failure,
/// an unexpected shape, or a GitHub error envelope (e.g. rate limiting).
final class LatestReleaseError extends LatestReleaseResult {
  final String message;
  const LatestReleaseError(this.message);
}

/// Classifies a GitHub `releases/latest` HTTP response into a
/// [LatestReleaseResult], given only the HTTP status code and decoded JSON
/// body (or `null`/an error shape on transport failure) -- no Dio/network
/// dependency, so this is directly unit-testable with hand-built inputs.
///
/// [allowPrerelease] defaults to `false`: prereleases are silently treated
/// as "not found" today (no update prompt), reserving the field for a
/// future opt-in beta channel without needing a different code path.
LatestReleaseResult parseLatestReleaseResponse(
  dynamic data, {
  int? statusCode,
  bool allowPrerelease = false,
}) {
  if (statusCode == 404) {
    return const LatestReleaseNotFound();
  }
  if (data is! Map) {
    return const LatestReleaseError(
      'unexpected response shape (expected a JSON object)',
    );
  }
  // GitHub's error envelope looks like {"message": "...", "documentation_url": "..."}
  // and has no tag_name. A malformed/missing tag_name on what looked like a
  // real release payload is likewise untrustworthy.
  final tagName = data['tag_name'];
  if (tagName is! String || tagName.isEmpty) {
    final message = data['message'];
    return LatestReleaseError(
      message is String && message.isNotEmpty
          ? message
          : 'release response missing tag_name',
    );
  }

  if (data['draft'] == true) {
    // /releases/latest never returns drafts, but guard anyway in case a
    // caller ever feeds this a release fetched some other way.
    return const LatestReleaseNotFound();
  }

  final prerelease = data['prerelease'] == true;
  if (prerelease && !allowPrerelease) {
    return const LatestReleaseNotFound();
  }

  final assets = <ReleaseAsset>[];
  final rawAssets = data['assets'];
  if (rawAssets is List) {
    for (final entry in rawAssets) {
      if (entry is Map) {
        final name = entry['name'];
        final url = entry['browser_download_url'];
        if (name is String &&
            name.isNotEmpty &&
            url is String &&
            url.isNotEmpty) {
          assets.add(ReleaseAsset(name: name, downloadUrl: url));
        }
      }
    }
  }

  return LatestReleaseFound(
    tagName: tagName,
    name: data['name'] as String?,
    body: data['body'] as String?,
    publishedAt: data['published_at'] as String?,
    createdAt: data['created_at'] as String?,
    htmlUrl: data['html_url'] as String?,
    assets: assets,
    prerelease: prerelease,
  );
}

// ---------------------------------------------------------------------------
// "Should we prompt for update" decision
// ---------------------------------------------------------------------------

/// Result of [decideShouldPromptUpdate]: whether to show the update dialog,
/// plus enough detail to explain *why* for debugging/tests.
class UpdateDecision {
  final bool shouldPrompt;

  /// The release tag's parsed `name+buildNumber`, if strict parsing
  /// succeeded. `null` when [usedDateFallback] is true.
  final ReleaseVersion? parsedTag;

  /// True if the release tag couldn't be strictly parsed and the decision
  /// fell back to comparing timestamps against the current build's
  /// `BuildConfig.buildTime`. This is always a degraded, best-effort path --
  /// see [decideShouldPromptUpdate] doc for exactly when it triggers.
  final bool usedDateFallback;

  const UpdateDecision({
    required this.shouldPrompt,
    this.parsedTag,
    this.usedDateFallback = false,
  });
}

/// Decides whether to prompt the user to update.
///
/// Primary signal (used whenever [releaseTag] parses via
/// [ReleaseVersion.tryParse]): prompt iff the release's build number is
/// strictly greater than [currentBuildNumber]. This is intentionally blind
/// to everything else -- release name, body, `created_at`/`published_at` --
/// so editing release notes or recreating a release under the same tag can
/// never cause spurious re-prompts, and a locally-built dev APK with a
/// later wall-clock build time than a real release still gets prompted if
/// the release's build number is actually higher.
///
/// Fallback (only reachable when [releaseTag] does NOT parse -- e.g. a
/// bare legacy-style tag like `v2.0.9` with no `+buildNumber`): falls back
/// to comparing [currentBuildTimeEpochSeconds] (`BuildConfig.buildTime`)
/// against the release's `published_at`/`created_at`. This exists purely
/// for backward compatibility with tags that don't carry a build number;
/// it is never used when the tag parses, and on its own can't be trusted
/// to say a build is *older* file-by-file, only "probably came out later".
/// If [currentBuildTimeEpochSeconds] is missing/zero (e.g. a manually-run
/// `flutter build apk` without `--dart-define=pili.time=...`) or the
/// release has no usable timestamp, the fallback conservatively reports no
/// prompt rather than guessing.
UpdateDecision decideShouldPromptUpdate({
  required int currentBuildNumber,
  required int currentBuildTimeEpochSeconds,
  required String releaseTag,
  String? releasePublishedAt,
  String? releaseCreatedAt,
}) {
  final parsed = ReleaseVersion.tryParse(releaseTag);
  if (parsed != null) {
    return UpdateDecision(
      shouldPrompt: parsed.buildNumber > currentBuildNumber,
      parsedTag: parsed,
    );
  }

  final dateStr = releasePublishedAt ?? releaseCreatedAt;
  if (dateStr == null || currentBuildTimeEpochSeconds <= 0) {
    return const UpdateDecision(shouldPrompt: false, usedDateFallback: true);
  }
  final DateTime date;
  try {
    date = DateTime.parse(dateStr);
  } catch (_) {
    return const UpdateDecision(shouldPrompt: false, usedDateFallback: true);
  }
  final releaseEpochSeconds = date.millisecondsSinceEpoch ~/ 1000;
  return UpdateDecision(
    shouldPrompt: currentBuildTimeEpochSeconds < releaseEpochSeconds,
    usedDateFallback: true,
  );
}

// ---------------------------------------------------------------------------
// Android ABI -> APK asset matching
// ---------------------------------------------------------------------------

/// Picks the best-matching Android APK asset for [supportedAbis] (ordered
/// most-preferred first, matching the order Android's
/// `Build.SUPPORTED_ABIS` / `device_info_plus`'s `supportedAbis` reports).
///
/// A match requires the asset's filename to both contain the ABI string
/// and end with `.apk` (both checked case-insensitively) -- this avoids
/// ever selecting `SHA256SUMS.txt`, a `.apk.sha256` checksum sidecar, or
/// any other non-APK file that happens to mention an ABI name. Returns
/// `null` if no asset matches any supported ABI (or [supportedAbis] is
/// empty), so callers can fall back to the release page.
ReleaseAsset? pickAndroidApkAsset(
  List<ReleaseAsset> assets,
  List<String> supportedAbis,
) {
  for (final abi in supportedAbis) {
    if (abi.isEmpty) continue;
    final lowerAbi = abi.toLowerCase();
    for (final asset in assets) {
      final lowerName = asset.name.toLowerCase();
      if (lowerName.endsWith('.apk') && lowerName.contains(lowerAbi)) {
        return asset;
      }
    }
  }
  return null;
}
