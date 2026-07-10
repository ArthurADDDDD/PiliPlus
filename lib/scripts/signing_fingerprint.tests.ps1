# Offline tests for lib/scripts/signing_fingerprint.ps1.
#
# Deliberately dependency-free (no Pester, no external module): plain
# assert-and-count so it runs on the stock `pwsh` already required by the
# release workflow, with nothing extra to install. Exercises only the pure
# functions (ConvertTo-NormalizedFingerprint, Test-FingerprintMatch,
# ConvertFrom-KeytoolCertOutput, ConvertFrom-ApksignerCertOutput) --
# Get-KeystoreCertFingerprint/Get-ApkCertFingerprint shell out to
# keytool/apksigner and are exercised for real only inside the GitHub
# Actions release job, not here.
#
# Run with:
#   pwsh lib/scripts/signing_fingerprint.tests.ps1
# Exits non-zero if any assertion fails.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/signing_fingerprint.ps1"

$script:passCount = 0
$script:failCount = 0
$script:failures = @()

function Assert-Equal {
    param(
        [string]$Name,
        $Expected,
        $Actual
    )
    if ($Expected -eq $Actual) {
        $script:passCount++
    } else {
        $script:failCount++
        $script:failures += "FAIL: $Name`n  expected: [$Expected]`n  actual:   [$Actual]"
    }
}

function Assert-Null {
    param([string]$Name, $Actual)
    Assert-Equal -Name $Name -Expected $true -Actual ($null -eq $Actual)
}

function Assert-True {
    param([string]$Name, [bool]$Actual)
    Assert-Equal -Name $Name -Expected $true -Actual $Actual
}

function Assert-False {
    param([string]$Name, [bool]$Actual)
    Assert-Equal -Name $Name -Expected $false -Actual $Actual
}

function Assert-Throws {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action | Out-Null
        $script:failCount++
        $script:failures += "FAIL: $Name`n  expected: <throws>`n  actual:   <no exception>"
    } catch {
        $script:passCount++
    }
}

$knownFingerprintLower = '2d02cc05ff51a2b2c020fe41cc764d3aa77b0d18448807e78a9b447505a1e349'
if ($knownFingerprintLower.Length -ne 64) {
    # Guards the test fixture itself against a typo -- this constant must
    # always be exactly 64 hex chars or every test below is meaningless.
    throw "test fixture bug: knownFingerprintLower is not 64 chars (got $($knownFingerprintLower.Length))"
}
$knownFingerprintUpper = $knownFingerprintLower.ToUpperInvariant()
$knownFingerprintColonUpper = ($knownFingerprintUpper -split '(?<=\G.{2})(?!$)') -join ':'

# ---------------------------------------------------------------------------
# ConvertTo-NormalizedFingerprint
# ---------------------------------------------------------------------------

Assert-Equal -Name 'lowercase, no colons, passes through unchanged' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertTo-NormalizedFingerprint $knownFingerprintLower)

Assert-Equal -Name 'uppercase, no colons, normalizes to lowercase' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertTo-NormalizedFingerprint $knownFingerprintUpper)

Assert-Equal -Name 'uppercase, with colons, normalizes to lowercase no colons' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertTo-NormalizedFingerprint $knownFingerprintColonUpper)

Assert-Equal -Name 'leading/trailing whitespace is trimmed' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertTo-NormalizedFingerprint "  $knownFingerprintLower  `t")

Assert-Equal -Name 'internal whitespace (space-separated hex pairs) is stripped' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertTo-NormalizedFingerprint (($knownFingerprintLower -split '(?<=\G.{2})(?!$)') -join ' '))

Assert-Null -Name 'illegal characters (non-hex) -> null' `
    -Actual (ConvertTo-NormalizedFingerprint 'zz02cc05ff51a2b2c020fe41cc764d3aa77b0d18448807e78a9b447505a1e349')

Assert-Null -Name 'fewer than 64 hex chars -> null' `
    -Actual (ConvertTo-NormalizedFingerprint '2d02cc05ff51a2b2')

Assert-Null -Name 'more than 64 hex chars -> null' `
    -Actual (ConvertTo-NormalizedFingerprint ($knownFingerprintLower + 'ab'))

Assert-Null -Name 'empty string -> null' -Actual (ConvertTo-NormalizedFingerprint '')
Assert-Null -Name 'whitespace-only string -> null' -Actual (ConvertTo-NormalizedFingerprint '   ')
Assert-Null -Name 'null input -> null' -Actual (ConvertTo-NormalizedFingerprint $null)

# ---------------------------------------------------------------------------
# Test-FingerprintMatch
# ---------------------------------------------------------------------------

Assert-True -Name 'match: identical lowercase strings' `
    -Actual (Test-FingerprintMatch -Expected $knownFingerprintLower -Actual $knownFingerprintLower)

Assert-True -Name 'match: lowercase vs. uppercase-with-colons of the same cert' `
    -Actual (Test-FingerprintMatch -Expected $knownFingerprintLower -Actual $knownFingerprintColonUpper)

Assert-True -Name 'match: both sides padded with whitespace' `
    -Actual (Test-FingerprintMatch -Expected " $knownFingerprintLower " -Actual "$knownFingerprintUpper`n")

$differentFingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
Assert-False -Name 'mismatch: two different valid fingerprints' `
    -Actual (Test-FingerprintMatch -Expected $knownFingerprintLower -Actual $differentFingerprint)

Assert-False -Name 'mismatch: expected side is malformed' `
    -Actual (Test-FingerprintMatch -Expected 'not-a-fingerprint' -Actual $knownFingerprintLower)

Assert-False -Name 'mismatch: actual side is malformed' `
    -Actual (Test-FingerprintMatch -Expected $knownFingerprintLower -Actual 'not-a-fingerprint')

Assert-False -Name 'mismatch: both sides empty' `
    -Actual (Test-FingerprintMatch -Expected '' -Actual '')

Assert-False -Name 'mismatch: expected null' `
    -Actual (Test-FingerprintMatch -Expected $null -Actual $knownFingerprintLower)

# ---------------------------------------------------------------------------
# ConvertFrom-KeytoolCertOutput (parsing real-shaped keytool -list -v text)
# ---------------------------------------------------------------------------

$keytoolOutputOk = @"
Alias name: androiddebugkey
Creation date: Jan 1, 2020
Entry type: PrivateKeyEntry
Certificate chain length: 1
Certificate[1]:
Owner: CN=Android Debug, O=Android, C=US
Issuer: CN=Android Debug, O=Android, C=US
Serial number: 1
Valid from: Wed Jan 01 00:00:00 UTC 2020 until: Sun Dec 26 00:00:00 UTC 2049
Certificate fingerprints:
	 SHA1: AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD
	 SHA256: 2D:02:CC:05:FF:51:A2:B2:C0:20:FE:41:CC:76:4D:3A:A7:7B:0D:18:44:88:07:E7:8A:9B:44:75:05:A1:E3:49
Signature algorithm name: SHA256withRSA
Subject Public Key Algorithm: 2048-bit RSA key
Version: 3
"@

Assert-Equal -Name 'keytool output: extracts SHA256 line correctly' `
    -Expected $knownFingerprintColonUpper `
    -Actual (ConvertFrom-KeytoolCertOutput $keytoolOutputOk)

Assert-True -Name 'keytool output: extracted value normalizes to the known fingerprint' `
    -Actual (Test-FingerprintMatch -Expected $knownFingerprintLower -Actual (ConvertFrom-KeytoolCertOutput $keytoolOutputOk))

$keytoolOutputBroken = @"
keytool error: java.io.IOException: Keystore was tampered with, or password was incorrect
"@
Assert-Null -Name 'keytool output: unparseable/error output -> null (caller must throw, not silently pass)' `
    -Actual (ConvertFrom-KeytoolCertOutput $keytoolOutputBroken)

Assert-Null -Name 'keytool output: empty string -> null' -Actual (ConvertFrom-KeytoolCertOutput '')
Assert-Null -Name 'keytool output: null -> null' -Actual (ConvertFrom-KeytoolCertOutput $null)

# ---------------------------------------------------------------------------
# ConvertFrom-ApksignerCertOutput (parsing real-shaped apksigner text)
# ---------------------------------------------------------------------------

$apksignerOutputOk = @"
Verifies
Verified using v1 scheme (JAR signing): true
Verified using v2 scheme (APK Signature Scheme v2): true
Verified using v3 scheme (APK Signature Scheme v3): true
Verified using v3.1 scheme (APK Signature Scheme v3.1): true
Verified using v4 scheme (APK Signature Scheme v4): false
Verified for SourceStamp: false
Number of signers: 1
Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
Signer #1 certificate SHA-256 digest: 2d02cc05ff51a2b2c020fe41cc764d3aa77b0d18448807e78a9b447505a1e349
Signer #1 certificate SHA-1 digest: aabbccddeeff00112233445566778899aabbccdd
Signer #1 certificate MD5 digest: 00112233445566778899aabbccddeeff
"@

Assert-Equal -Name 'apksigner output: extracts SHA-256 digest line correctly' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputOk)

Assert-True -Name 'apksigner output: extracted value matches the known fingerprint' `
    -Actual (Test-FingerprintMatch -Expected $knownFingerprintLower -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputOk))

$apksignerOutputBroken = @"
DOES NOT VERIFY
ERROR: JAR_SIG_NO_SIGNATURES: No JAR signatures found
"@
Assert-Null -Name 'apksigner output: unparseable/failed-verify output -> null' `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputBroken)

Assert-Null -Name 'apksigner output: empty string -> null' -Actual (ConvertFrom-ApksignerCertOutput '')
Assert-Null -Name 'apksigner output: null -> null' -Actual (ConvertFrom-ApksignerCertOutput $null)

# ---------------------------------------------------------------------------
# ConvertFrom-ApksignerCertOutput: modern (v3/v3.1 rotation-aware) formats,
# added for the "could not find a 'Signer #1 certificate SHA-256 digest'
# line" CI failure against real-world apksigner output that reports signers
# as "Signer (minSdkVersion=.., maxSdkVersion=..)" instead of "Signer #1".
# ---------------------------------------------------------------------------

$apksignerOutputMinMaxSdk = @"
Verifies
Verified using v3.1 scheme (APK Signature Scheme v3.1): true
Signer (minSdkVersion=24, maxSdkVersion=32) certificate DN: CN=Android Debug, O=Android, C=US
Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: $knownFingerprintLower
"@
Assert-Equal -Name 'apksigner output: Signer (minSdkVersion=.., maxSdkVersion=..) format' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputMinMaxSdk)

$apksignerOutputDevRelease = @"
Verifies
Signer (minSdkVersion=33 (dev release=true), maxSdkVersion=100000) certificate SHA-256 digest: $knownFingerprintLower
"@
Assert-Equal -Name 'apksigner output: Signer (... (dev release=true) ...) nested-description format' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputDevRelease)

Assert-Equal -Name 'apksigner output: uppercase "SIGNER"/"SHA-256" is matched case-insensitively' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput "SIGNER #1 CERTIFICATE SHA-256 DIGEST: $knownFingerprintUpper")

$apksignerOutputCrLf = "Verifies`r`nSigner #1 certificate SHA-256 digest: $knownFingerprintLower`r`n"
Assert-Equal -Name 'apksigner output: CRLF line endings' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputCrLf)

Assert-Equal -Name 'apksigner output: leading/trailing whitespace around the signer line' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput "   Signer #1 certificate SHA-256 digest: $knownFingerprintLower   ")

# Simulates Out-String/console-width wrapping splitting the hex digest
# itself across two lines, right after the colon.
$apksignerOutputWrapped = @"
Signer #1 certificate SHA-256 digest:
$knownFingerprintLower
"@
Assert-Equal -Name 'apksigner output: fingerprint wrapped onto the following line' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputWrapped)

# Simulates the wrap happening mid-digest rather than right after the colon.
$halfLen = [int]($knownFingerprintLower.Length / 2)
$apksignerOutputWrappedMidDigest = @"
Signer #1 certificate SHA-256 digest: $($knownFingerprintLower.Substring(0, $halfLen))
$($knownFingerprintLower.Substring($halfLen))
"@
Assert-Equal -Name 'apksigner output: fingerprint wrapped mid-digest onto the following line' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputWrappedMidDigest)

$apksignerOutputSameFingerprintTwice = @"
Verified using v1 scheme (JAR signing): true
Verified using v2 scheme (APK Signature Scheme v2): true
Signer #1 certificate SHA-256 digest: $knownFingerprintLower
Signer #1 certificate SHA-256 digest: $knownFingerprintLower
"@
Assert-Equal -Name 'apksigner output: identical fingerprint reported twice (v1+v2) still resolves to one value' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputSameFingerprintTwice)

$apksignerOutputSameFingerprintDifferentSignerLines = @"
Signer #1 certificate SHA-256 digest: $knownFingerprintLower
Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: $knownFingerprintUpper
Signer (minSdkVersion=33 (dev release=true), maxSdkVersion=100000) certificate SHA-256 digest: $knownFingerprintLower
"@
Assert-Equal -Name 'apksigner output: same fingerprint via different Signer-line variants still resolves to one value' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputSameFingerprintDifferentSignerLines)

$apksignerOutputTwoDifferentFingerprints = @"
Signer #1 certificate SHA-256 digest: $knownFingerprintLower
Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: $differentFingerprint
"@
Assert-Throws -Name 'apksigner output: two genuinely different fingerprints -> ambiguous, throws (must not pick the first)' `
    -Action { ConvertFrom-ApksignerCertOutput $apksignerOutputTwoDifferentFingerprints }

$apksignerOutputPublicKeyOnly = @"
Signer #1 certificate DN: CN=Android Debug, O=Android, C=US
Signer #1 public key SHA-256 digest: $differentFingerprint
"@
Assert-Null -Name 'apksigner output: must not mis-select a "public key SHA-256 digest" line' `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputPublicKeyOnly)

$apksignerOutputSourceStampOnly = @"
Verified for SourceStamp: true
Source Stamp Signer certificate DN: CN=Source Stamp, O=Android, C=US
Source Stamp Signer certificate SHA-256 digest: $differentFingerprint
"@
Assert-Null -Name 'apksigner output: must not mis-select a "Source Stamp Signer certificate SHA-256 digest" line' `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputSourceStampOnly)

$apksignerOutputPublicKeyAndRealSigner = @"
Signer #1 certificate SHA-256 digest: $knownFingerprintLower
Signer #1 public key SHA-256 digest: $differentFingerprint
Source Stamp Signer certificate SHA-256 digest: $differentFingerprint
"@
Assert-Equal -Name 'apksigner output: real signer digest picked correctly alongside public-key/Source-Stamp noise' `
    -Expected $knownFingerprintLower `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputPublicKeyAndRealSigner)

$apksignerOutput63CharDigest = @"
Signer #1 certificate SHA-256 digest: $($knownFingerprintLower.Substring(0, 63))
Signer #1 certificate SHA-1 digest: aabbccddeeff00112233445566778899aabbccdd
"@
Assert-Null -Name 'apksigner output: 63-hex-char (too short) digest -> null, not accepted' `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutput63CharDigest)

$apksignerOutput65CharDigest = @"
Signer #1 certificate SHA-256 digest: $($knownFingerprintLower)a
Signer #1 certificate SHA-1 digest: aabbccddeeff00112233445566778899aabbccdd
"@
Assert-Null -Name 'apksigner output: 65-hex-char (too long) digest -> null, not accepted' `
    -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutput65CharDigest)

# ---------------------------------------------------------------------------
# End-to-end: keystore fingerprint and APK fingerprint agreeing/disagreeing
# with an expected value, exactly as the release workflow's two preflight
# checks will use these functions.
# ---------------------------------------------------------------------------

$expectedFromVariable = ' 2D:02:CC:05:FF:51:A2:B2:C0:20:FE:41:CC:76:4D:3A:A7:7B:0D:18:44:88:07:E7:8A:9B:44:75:05:A1:E3:49 '
Assert-True -Name 'end-to-end: keystore fingerprint matches EXPECTED_SIGNING_CERT_SHA256-style input' `
    -Actual (Test-FingerprintMatch -Expected $expectedFromVariable -Actual (ConvertFrom-KeytoolCertOutput $keytoolOutputOk))
Assert-True -Name 'end-to-end: APK fingerprint matches EXPECTED_SIGNING_CERT_SHA256-style input' `
    -Actual (Test-FingerprintMatch -Expected $expectedFromVariable -Actual (ConvertFrom-ApksignerCertOutput $apksignerOutputOk))

$wrongExpected = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
Assert-False -Name 'end-to-end: keystore fingerprint correctly flagged as mismatched' `
    -Actual (Test-FingerprintMatch -Expected $wrongExpected -Actual (ConvertFrom-KeytoolCertOutput $keytoolOutputOk))

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "signing_fingerprint tests: $script:passCount passed, $script:failCount failed"
if ($script:failCount -gt 0) {
    Write-Host ""
    foreach ($f in $script:failures) {
        Write-Host $f
    }
    exit 1
}
exit 0
