# Reusable signing-certificate-fingerprint helpers, shared by the GitHub
# Actions release workflow (.github/workflows/build.yml) and by
# lib/scripts/signing_fingerprint.tests.ps1 (offline tests, no keystore/APK
# required -- feeds hand-built keytool/apksigner-style text into the pure
# parsing functions below).
#
# Meant to be dot-sourced, e.g.:
#   . "$PSScriptRoot/signing_fingerprint.ps1"
#   ConvertTo-NormalizedFingerprint "2D:02:CC:..."
#
# Pure functions (no I/O, safe to unit test with hand-built strings):
#   ConvertTo-NormalizedFingerprint
#   Test-FingerprintMatch
#   ConvertFrom-KeytoolCertOutput
#   ConvertFrom-ApksignerCertOutput
#
# Impure functions (shell out to keytool/apksigner; not covered by offline
# tests, only exercised for real inside the GitHub Actions release job):
#   Get-KeystoreCertFingerprint
#   Get-ApkCertFingerprint
#
# No third-party dependency (no Pester, no external module) -- everything
# here is plain PowerShell so it runs on the stock `pwsh` that ships on
# GitHub-hosted runners with nothing extra to install.

Set-StrictMode -Version Latest

# Normalizes a certificate fingerprint string for comparison: lowercases,
# strips colons/whitespace, and validates the result is exactly 64 hex
# characters (a SHA-256 digest). Returns $null for anything that doesn't
# come out looking like a valid SHA-256 hex digest -- callers should treat
# a $null result as "untrustworthy input", never as a wildcard match.
function ConvertTo-NormalizedFingerprint {
    param(
        [AllowNull()]
        [string]$Raw
    )
    if ($null -eq $Raw) {
        return $null
    }
    $stripped = ($Raw -replace '[:\s]', '').Trim()
    if ($stripped.Length -eq 0) {
        return $null
    }
    $lower = $stripped.ToLowerInvariant()
    if ($lower -notmatch '^[0-9a-f]{64}$') {
        return $null
    }
    return $lower
}

# Compares two fingerprint strings (in any of the accepted input formats --
# lower/upper case, with/without colons, with/without surrounding
# whitespace) for equality after normalization. Returns $false (never
# throws) if either side fails to normalize to a valid 64-hex-char SHA-256
# digest -- an unparseable "expected" or "actual" value must never be
# treated as a match.
function Test-FingerprintMatch {
    param(
        [AllowNull()][string]$Expected,
        [AllowNull()][string]$Actual
    )
    $normExpected = ConvertTo-NormalizedFingerprint $Expected
    $normActual = ConvertTo-NormalizedFingerprint $Actual
    if ($null -eq $normExpected -or $null -eq $normActual) {
        return $false
    }
    return $normExpected -eq $normActual
}

# Extracts the SHA-256 certificate fingerprint from `keytool -list -v`
# output text, e.g. a line like:
#   Certificate fingerprints:
#            SHA256: 2D:02:CC:05:FF:51:A2:B2:C0:20:FE:41:CC:76:4D:3A:...
# Returns $null (does not throw) if no such line is found, so callers can
# distinguish "ran fine but nothing to parse" from a hard I/O failure.
function ConvertFrom-KeytoolCertOutput {
    param([AllowNull()][string]$KeytoolOutput)
    if ([string]::IsNullOrEmpty($KeytoolOutput)) {
        return $null
    }
    $match = [regex]::Match($KeytoolOutput, '(?im)^\s*SHA256:\s*([0-9A-Fa-f:]+)\s*$')
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value
}

# Extracts the SHA-256 certificate fingerprint from
# `apksigner verify --verbose --print-certs` output text, e.g. a line like:
#   Signer #1 certificate SHA-256 digest: 2d02cc05ff51a2b2c020fe41cc764d3a...
# Returns $null (does not throw) if no such line is found.
function ConvertFrom-ApksignerCertOutput {
    param([AllowNull()][string]$ApksignerOutput)
    if ([string]::IsNullOrEmpty($ApksignerOutput)) {
        return $null
    }
    $match = [regex]::Match(
        $ApksignerOutput,
        '(?im)^\s*Signer\s*#1\s*certificate\s*SHA-256\s*digest:\s*([0-9A-Fa-f]+)\s*$'
    )
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value
}

# Reads the SHA-256 fingerprint of the certificate for [Alias] inside
# [KeystorePath], by shelling out to `keytool -list -v`. Throws (with a
# message that never includes [StorePassword]) if keytool fails to open
# the keystore/alias, or if its output can't be parsed for a fingerprint.
function Get-KeystoreCertFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$KeystorePath,
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][string]$StorePassword
    )
    $output = & keytool -list -v -keystore $KeystorePath -alias $Alias -storepass $StorePassword 2>&1 |
        Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "keytool could not read alias '$Alias' from keystore '$KeystorePath' (exit code $LASTEXITCODE). Check the keystore file and KEY_ALIAS/KEYSTORE_PASSWORD secrets."
    }
    $fingerprint = ConvertFrom-KeytoolCertOutput $output
    if ($null -eq $fingerprint) {
        throw "could not find a SHA256 fingerprint line in keytool output for alias '$Alias'."
    }
    return $fingerprint
}

# Reads the SHA-256 fingerprint of the (first) signer certificate of an
# APK, by shelling out to `apksigner verify --verbose --print-certs`.
# Throws if apksigner itself reports the APK as unverifiable, or if its
# output can't be parsed for a fingerprint.
function Get-ApkCertFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$ApksignerPath,
        [Parameter(Mandatory = $true)][string]$ApkPath
    )
    $output = & $ApksignerPath verify --verbose --print-certs $ApkPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "apksigner verify failed for '$ApkPath' (exit code $LASTEXITCODE):`n$output"
    }
    $fingerprint = ConvertFrom-ApksignerCertOutput $output
    if ($null -eq $fingerprint) {
        throw "could not find a 'Signer #1 certificate SHA-256 digest' line in apksigner output for '$ApkPath'."
    }
    return $fingerprint
}
