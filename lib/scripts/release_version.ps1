param(
    [Parameter(Mandatory = $true)]
    [string]$Tag
)

# Formal-release version/tag preflight, used only by the GitHub Actions
# "release" path in .github/workflows/build.yml (workflow_dispatch with a
# non-empty `tag` input).
#
# Unlike lib/scripts/build.ps1 (used for PR/dev/test builds, which computes
# an ever-increasing build number from `git rev-list --count HEAD` and
# rewrites pubspec.yaml with it), a FORMAL release treats pubspec.yaml's
# `version:` line as the single source of truth: the maintainer edits it by
# hand (e.g. `version: 2.0.9+5103`), commits it, and only THEN triggers the
# release workflow with a matching tag (e.g. `v2.0.9+5103`). This script
# only validates that the two agree and extracts values for later steps --
# it never mutates pubspec.yaml and never invents its own build number, so
# a formal release has exactly one place its version comes from.
#
# Fails closed (non-zero exit) on any mismatch or malformed input, per the
# release preflight requirements: a formal release must not go out with an
# ambiguous or incorrect version.

$ErrorActionPreference = 'Stop'

try {
    $versionLine = (Get-Content -Path 'pubspec.yaml' -Encoding UTF8 |
        Where-Object { $_ -match '^\s*version:\s*(\S+)' } |
        Select-Object -First 1)

    if ($null -eq $versionLine) {
        throw "pubspec.yaml has no 'version:' line."
    }

    $null = $versionLine -match '^\s*version:\s*(\S+)'
    $pubspecVersion = $matches[1]

    if ($pubspecVersion -notmatch '^(\d+\.\d+\.\d+)\+(\d+)$') {
        throw "pubspec.yaml version '$pubspecVersion' is not in '<versionName>+<buildNumber>' form (e.g. 2.0.9+5103). Set it by hand before releasing -- see docs/RELEASE_GUIDE.md."
    }
    $versionName = $matches[1]
    $versionCode = [int]$matches[2]

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        throw "tag is empty. A formal release requires a non-empty tag matching pubspec.yaml's version."
    }

    $normalizedTag = $Tag.Trim()
    if ($normalizedTag -match '^[vV](\d.*)$') {
        $normalizedTag = $matches[1]
    }

    if ($normalizedTag -notmatch '^(\d+\.\d+\.\d+)\+(\d+)$') {
        throw "tag '$Tag' is not a valid release tag. Expected 'v<versionName>+<buildNumber>' (e.g. v2.0.9+5103)."
    }
    $tagVersionName = $matches[1]
    $tagVersionCode = [int]$matches[2]

    if ($tagVersionName -ne $versionName -or $tagVersionCode -ne $versionCode) {
        throw "tag '$Tag' (parsed as $tagVersionName+$tagVersionCode) does not match pubspec.yaml version '$pubspecVersion'. Edit pubspec.yaml to match the tag (or vice versa) and commit before releasing -- a formal release must not go out with a version/tag mismatch."
    }

    $commitHash = (git rev-parse HEAD).Trim()
    $buildTime = [int]([DateTimeOffset]::Now.ToUnixTimeSeconds())

    $data = @{
        'pili.name' = $versionName
        'pili.code' = $versionCode
        'pili.hash' = $commitHash
        'pili.time' = $buildTime
    }
    $data | ConvertTo-Json -Compress | Out-File 'pili_release.json' -Encoding UTF8

    Add-Content -Path $env:GITHUB_ENV -Value "version=$versionName+$versionCode"
    Add-Content -Path $env:GITHUB_ENV -Value "versionName=$versionName"
    Add-Content -Path $env:GITHUB_ENV -Value "versionCode=$versionCode"
    Add-Content -Path $env:GITHUB_ENV -Value "commitHash=$commitHash"
    Add-Content -Path $env:GITHUB_ENV -Value "buildTime=$buildTime"

    Write-Host "Release preflight OK: pubspec.yaml version '$pubspecVersion' matches tag '$Tag'."
}
catch {
    Write-Error "Release version preflight failed: $($_.Exception.Message)"
    exit 1
}
