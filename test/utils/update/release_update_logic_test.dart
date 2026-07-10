// Offline unit tests for the fork's self-update logic
// (lib/utils/update/release_update_logic.dart). Pure functions/classes
// only -- no network, no Flutter widgets, no device required.
import 'package:PiliPlus/utils/update/release_update_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReleaseVersion.tryParse', () {
    test('parses a tag with leading v', () {
      final v = ReleaseVersion.tryParse('v2.0.9+5103');
      expect(v, isNotNull);
      expect(v!.name, '2.0.9');
      expect(v.buildNumber, 5103);
    });

    test('parses a tag without leading v', () {
      final v = ReleaseVersion.tryParse('2.0.9+5103');
      expect(v!.name, '2.0.9');
      expect(v.buildNumber, 5103);
    });

    test('parses uppercase V prefix', () {
      final v = ReleaseVersion.tryParse('V2.0.9+5103');
      expect(v!.name, '2.0.9');
      expect(v.buildNumber, 5103);
    });

    test('rejects a bare tag with no build number (legacy upstream style)', () {
      expect(ReleaseVersion.tryParse('v2.0.9'), isNull);
    });

    test('rejects an invalid tag', () {
      expect(ReleaseVersion.tryParse('not-a-version'), isNull);
    });

    test('rejects an empty tag', () {
      expect(ReleaseVersion.tryParse(''), isNull);
      expect(ReleaseVersion.tryParse('   '), isNull);
    });

    test('rejects a null tag', () {
      expect(ReleaseVersion.tryParse(null), isNull);
    });

    test('accepts an extremely large build number', () {
      final v = ReleaseVersion.tryParse('v2.0.9+999999999999');
      expect(v, isNotNull);
      expect(v!.buildNumber, 999999999999);
    });

    test('rejects a non-integer build number', () {
      expect(ReleaseVersion.tryParse('v2.0.9+abc'), isNull);
      expect(ReleaseVersion.tryParse('v2.0.9+1.5'), isNull);
    });

    test('trims surrounding whitespace', () {
      final v = ReleaseVersion.tryParse('  v2.0.9+5103  ');
      expect(v!.buildNumber, 5103);
    });

    test('equality is based on name and buildNumber', () {
      expect(
        ReleaseVersion.tryParse('v2.0.9+5103'),
        ReleaseVersion.tryParse('2.0.9+5103'),
      );
    });
  });

  group('parseLatestReleaseResponse', () {
    test('parses a normal single release map', () {
      final result = parseLatestReleaseResponse({
        'tag_name': 'v2.0.9+5103',
        'name': 'PiliPlus 2.0.9',
        'body': 'release notes',
        'published_at': '2026-07-10T00:00:00Z',
        'created_at': '2026-07-09T00:00:00Z',
        'html_url':
            'https://github.com/ArthurADDDDD/PiliPlus/releases/tag/v2.0.9+5103',
        'draft': false,
        'prerelease': false,
        'assets': [
          {
            'name': 'PiliPlus_android_2.0.9+5103_arm64-v8a.apk',
            'browser_download_url': 'https://example.com/arm64.apk',
          },
        ],
      }, statusCode: 200);

      expect(result, isA<LatestReleaseFound>());
      final found = result as LatestReleaseFound;
      expect(found.tagName, 'v2.0.9+5103');
      expect(found.name, 'PiliPlus 2.0.9');
      expect(found.assets, hasLength(1));
      expect(
        found.assets.first.name,
        'PiliPlus_android_2.0.9+5103_arm64-v8a.apk',
      );
    });

    test('404 means no release published yet, not an error', () {
      final result = parseLatestReleaseResponse(
        {'message': 'Not Found'},
        statusCode: 404,
      );
      expect(result, isA<LatestReleaseNotFound>());
    });

    test('empty/non-map response is an error', () {
      expect(parseLatestReleaseResponse(null), isA<LatestReleaseError>());
      expect(parseLatestReleaseResponse('oops'), isA<LatestReleaseError>());
      expect(parseLatestReleaseResponse([1, 2, 3]), isA<LatestReleaseError>());
    });

    test('a GitHub error envelope Map is classified as an error', () {
      final result = parseLatestReleaseResponse({
        'message': 'API rate limit exceeded',
      }, statusCode: 403);
      expect(result, isA<LatestReleaseError>());
      expect((result as LatestReleaseError).message, 'API rate limit exceeded');
    });

    test('a release map missing tag_name is an error', () {
      final result = parseLatestReleaseResponse({
        'name': 'no tag here',
      }, statusCode: 200);
      expect(result, isA<LatestReleaseError>());
    });

    test('a release map missing assets still parses with an empty list', () {
      final result = parseLatestReleaseResponse({
        'tag_name': 'v2.0.9+5103',
      }, statusCode: 200);
      expect(result, isA<LatestReleaseFound>());
      expect((result as LatestReleaseFound).assets, isEmpty);
    });

    test('draft releases are treated as not-found', () {
      final result = parseLatestReleaseResponse({
        'tag_name': 'v2.0.9+5103',
        'draft': true,
      }, statusCode: 200);
      expect(result, isA<LatestReleaseNotFound>());
    });

    test('prerelease releases are treated as not-found by default', () {
      final result = parseLatestReleaseResponse({
        'tag_name': 'v2.1.0-beta+5200',
        'prerelease': true,
      }, statusCode: 200);
      expect(result, isA<LatestReleaseNotFound>());
    });

    test('prerelease releases surface when allowPrerelease is true', () {
      final result = parseLatestReleaseResponse(
        {
          'tag_name': 'v2.1.0-beta+5200',
          'prerelease': true,
        },
        statusCode: 200,
        allowPrerelease: true,
      );
      expect(result, isA<LatestReleaseFound>());
      expect((result as LatestReleaseFound).prerelease, isTrue);
    });

    test('malformed asset entries are skipped, not crashed on', () {
      final result = parseLatestReleaseResponse({
        'tag_name': 'v2.0.9+5103',
        'assets': [
          {'name': 'ok.apk', 'browser_download_url': 'https://x/ok.apk'},
          {'name': 'missing-url.apk'},
          'not-a-map',
          42,
          null,
        ],
      }, statusCode: 200);
      final found = result as LatestReleaseFound;
      expect(found.assets, hasLength(1));
      expect(found.assets.single.name, 'ok.apk');
    });
  });

  group('decideShouldPromptUpdate', () {
    test('prompts when release build number is greater', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'v2.0.9+101',
      );
      expect(decision.shouldPrompt, isTrue);
      expect(decision.usedDateFallback, isFalse);
      expect(decision.parsedTag!.buildNumber, 101);
    });

    test('does not prompt when build numbers are equal', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'v2.0.9+100',
      );
      expect(decision.shouldPrompt, isFalse);
    });

    test(
      'does not prompt (no downgrade) when release build number is lower',
      () {
        final decision = decideShouldPromptUpdate(
          currentBuildNumber: 200,
          currentBuildTimeEpochSeconds: 1000,
          releaseTag: 'v2.0.9+100',
        );
        expect(decision.shouldPrompt, isFalse);
      },
    );

    test('tag with leading v parses the same as without', () {
      final withV = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'v2.0.9+101',
      );
      final withoutV = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: '2.0.9+101',
      );
      expect(withV.shouldPrompt, withoutV.shouldPrompt);
      expect(withV.parsedTag, withoutV.parsedTag);
    });

    test('invalid tag falls back to date comparison', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'not-a-valid-tag',
        releaseCreatedAt: DateTime.fromMillisecondsSinceEpoch(
          2000 * 1000,
        ).toIso8601String(),
      );
      expect(decision.usedDateFallback, isTrue);
      expect(decision.shouldPrompt, isTrue);
      expect(decision.parsedTag, isNull);
    });

    test('empty tag falls back to date comparison and does not crash', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: '',
      );
      expect(decision.usedDateFallback, isTrue);
      expect(decision.shouldPrompt, isFalse);
    });

    test('extremely large build number is handled correctly', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'v9.9.9+999999999999',
      );
      expect(decision.shouldPrompt, isTrue);
    });

    test(
      'versionName changing without build number increasing does not prompt',
      () {
        // Same build number, different display name (e.g. a re-tagged rebuild
        // with a cosmetic rename) must not trigger a prompt -- only the build
        // number matters.
        final decision = decideShouldPromptUpdate(
          currentBuildNumber: 100,
          currentBuildTimeEpochSeconds: 1000,
          releaseTag: 'v3.0.0-renamed+100',
        );
        expect(decision.shouldPrompt, isFalse);
      },
    );

    test('created_at changing with the same version does not prompt', () {
      // Editing a release's timestamp/body without bumping the tag must not
      // cause a re-prompt -- decideShouldPromptUpdate never looks at dates
      // when the tag parses.
      final first = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'v2.0.9+100',
        releaseCreatedAt: '2026-01-01T00:00:00Z',
      );
      final second = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'v2.0.9+100',
        releaseCreatedAt: '2026-07-10T00:00:00Z',
      );
      expect(first.shouldPrompt, isFalse);
      expect(second.shouldPrompt, isFalse);
    });

    test(
      'local build time later than release date does not suppress a prompt '
      'when the release build number is actually higher',
      () {
        // currentBuildTimeEpochSeconds is *ahead* of the release's date --
        // if date were used as the primary signal this would wrongly look
        // "already newer". The tag's build number must win.
        final decision = decideShouldPromptUpdate(
          currentBuildNumber: 100,
          currentBuildTimeEpochSeconds: 99999999999,
          releaseTag: 'v2.0.9+101',
          releaseCreatedAt: '2020-01-01T00:00:00Z',
        );
        expect(decision.shouldPrompt, isTrue);
        expect(decision.usedDateFallback, isFalse);
      },
    );

    test('date fallback with zero currentBuildTime never prompts', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 0,
        releaseTag: 'v2.0.9', // unparseable, no build number
        releaseCreatedAt: '2026-07-10T00:00:00Z',
      );
      expect(decision.usedDateFallback, isTrue);
      expect(decision.shouldPrompt, isFalse);
    });

    test('date fallback with an unparseable date does not crash', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1000,
        releaseTag: 'v2.0.9',
        releaseCreatedAt: 'not-a-date',
      );
      expect(decision.usedDateFallback, isTrue);
      expect(decision.shouldPrompt, isFalse);
    });

    test('date fallback prefers publishedAt over createdAt', () {
      final decision = decideShouldPromptUpdate(
        currentBuildNumber: 100,
        currentBuildTimeEpochSeconds: 1500,
        releaseTag: 'v2.0.9',
        releasePublishedAt: DateTime.fromMillisecondsSinceEpoch(
          2000 * 1000,
        ).toIso8601String(),
        releaseCreatedAt: DateTime.fromMillisecondsSinceEpoch(
          1000 * 1000,
        ).toIso8601String(),
      );
      // publishedAt (2000) > currentBuildTime (1500) -> should prompt.
      expect(decision.shouldPrompt, isTrue);
    });
  });

  group('pickAndroidApkAsset', () {
    ReleaseAsset asset(String name) =>
        ReleaseAsset(name: name, downloadUrl: 'https://example.com/$name');

    test('exact arm64-v8a match', () {
      final assets = [
        asset('PiliPlus_android_2.0.9+5103_arm64-v8a.apk'),
        asset('PiliPlus_android_2.0.9+5103_armeabi-v7a.apk'),
      ];
      final picked = pickAndroidApkAsset(assets, ['arm64-v8a']);
      expect(picked, isNotNull);
      expect(picked!.name, contains('arm64-v8a'));
    });

    test('exact armeabi-v7a match', () {
      final assets = [asset('PiliPlus_android_2.0.9+5103_armeabi-v7a.apk')];
      final picked = pickAndroidApkAsset(assets, ['armeabi-v7a']);
      expect(picked!.name, contains('armeabi-v7a'));
    });

    test('exact x86_64 match', () {
      final assets = [asset('PiliPlus_android_2.0.9+5103_x86_64.apk')];
      final picked = pickAndroidApkAsset(assets, ['x86_64']);
      expect(picked!.name, contains('x86_64'));
    });

    test('case-insensitive asset name matching', () {
      final assets = [asset('PiliPlus_Android_2.0.9+5103_ARM64-V8A.APK')];
      final picked = pickAndroidApkAsset(assets, ['arm64-v8a']);
      expect(picked, isNotNull);
    });

    test('case-insensitive ABI matching', () {
      final assets = [asset('PiliPlus_android_2.0.9+5103_arm64-v8a.apk')];
      final picked = pickAndroidApkAsset(assets, ['ARM64-V8A']);
      expect(picked, isNotNull);
    });

    test('multiple APKs in a release: picks the one matching the ABI', () {
      final assets = [
        asset('PiliPlus_android_2.0.9+5103_arm64-v8a.apk'),
        asset('PiliPlus_android_2.0.9+5103_armeabi-v7a.apk'),
        asset('PiliPlus_android_2.0.9+5103_x86_64.apk'),
      ];
      expect(pickAndroidApkAsset(assets, ['x86_64'])!.name, contains('x86_64'));
    });

    test(
      'only checksum file present, no APK -> null (fallback to release page)',
      () {
        final assets = [asset('SHA256SUMS.txt')];
        expect(pickAndroidApkAsset(assets, ['arm64-v8a']), isNull);
      },
    );

    test('empty supportedAbis is a safe no-match, not a crash', () {
      final assets = [asset('PiliPlus_android_2.0.9+5103_arm64-v8a.apk')];
      expect(pickAndroidApkAsset(assets, []), isNull);
    });

    test('first ABI has no asset, second ABI does -> picks the second', () {
      final assets = [asset('PiliPlus_android_2.0.9+5103_armeabi-v7a.apk')];
      final picked = pickAndroidApkAsset(assets, ['arm64-v8a', 'armeabi-v7a']);
      expect(picked, isNotNull);
      expect(picked!.name, contains('armeabi-v7a'));
    });

    test('does not mis-select .sha256 sidecar files', () {
      final assets = [
        asset('PiliPlus_android_2.0.9+5103_arm64-v8a.apk.sha256'),
        asset('PiliPlus_android_2.0.9+5103_arm64-v8a.apk'),
      ];
      final picked = pickAndroidApkAsset(assets, ['arm64-v8a']);
      expect(picked!.name, 'PiliPlus_android_2.0.9+5103_arm64-v8a.apk');
    });

    test('does not mis-select .json files', () {
      final assets = [
        asset('arm64-v8a-metadata.json'),
      ];
      expect(pickAndroidApkAsset(assets, ['arm64-v8a']), isNull);
    });

    test('no matching asset for any supported ABI -> null', () {
      final assets = [asset('PiliPlus_android_2.0.9+5103_x86_64.apk')];
      expect(pickAndroidApkAsset(assets, ['arm64-v8a', 'armeabi-v7a']), isNull);
    });
  });
}
