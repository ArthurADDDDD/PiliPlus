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
# `apksigner verify --verbose --print-certs` output text.
#
# Modern apksigner (APK Signature Scheme v3/v3.1, key-rotation-aware) does
# not always print a fixed "Signer #1 certificate SHA-256 digest:" line --
# it may instead print one block per rotation range, e.g.:
#   Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: ...
#   Signer (minSdkVersion=33 (dev release=true), maxSdkVersion=100000) certificate SHA-256 digest: ...
# so this must match any "Signer ... certificate SHA-256 digest:" line, not
# only a literal "Signer #1" prefix. It must NOT match sibling lines such as
# "Signer #1 public key SHA-256 digest: ..." (different digest kind) or
# "Source Stamp Signer certificate SHA-256 digest: ..." (a different,
# unrelated signer -- that line does not start with "Signer", so anchoring
# each candidate at the start of the (trimmed) line already excludes it).
#
# Handles both CRLF and LF line endings, case-insensitive "Signer"/"SHA-256"
# spelling, leading/trailing whitespace, and a fingerprint value that has
# been wrapped onto one or more following lines (e.g. by PowerShell's
# console-width-dependent Out-String formatting) by greedily absorbing
# subsequent hex-only lines until 64 hex characters have been collected.
#
# The same certificate commonly appears more than once (once per signature
# scheme, and/or once per rotation range) -- that's fine, duplicates
# collapse to a single value. If genuinely different fingerprints are found
# (an ambiguous result), this throws rather than silently returning the
# first match, since guessing wrong here would defeat the whole point of a
# signing-certificate check.
#
# Returns $null (does not throw) if no matching line is found at all, so
# callers can distinguish "ran fine but nothing to parse" from a hard
# failure. Throws only for the genuinely-ambiguous multiple-distinct-
# fingerprints case.
function ConvertFrom-ApksignerCertOutput {
    param([AllowNull()][string]$ApksignerOutput)
    if ([string]::IsNullOrEmpty($ApksignerOutput)) {
        return $null
    }

    $lines = $ApksignerOutput -split '\r?\n'
    $signerLineRegex = [regex]'(?i)^Signer\b.*?certificate\s+SHA-256\s+digest:\s*(.*)$'
    $hexOnlyRegex = [regex]'^[0-9A-Fa-f]+$'
    $fingerprints = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        $lineMatch = $signerLineRegex.Match($line)
        if (-not $lineMatch.Success) {
            continue
        }

        $hexChunks = [System.Collections.Generic.List[string]]::new()
        $firstChunk = $lineMatch.Groups[1].Value.Trim()
        if ($firstChunk.Length -gt 0) {
            $hexChunks.Add($firstChunk)
        }

        # The fingerprint value may have been wrapped onto the following
        # line(s); keep absorbing hex-only lines until we have at least a
        # full 64-char digest (or run out of hex-only lines to absorb).
        $j = $i + 1
        while ($j -lt $lines.Count -and ($hexChunks -join '').Length -lt 64) {
            $nextLine = $lines[$j].Trim()
            if ($nextLine.Length -eq 0 -or -not $hexOnlyRegex.IsMatch($nextLine)) {
                break
            }
            $hexChunks.Add($nextLine)
            $j++
        }

        $candidate = ConvertTo-NormalizedFingerprint ($hexChunks -join '')
        if ($null -ne $candidate) {
            $fingerprints.Add($candidate)
        }
    }

    $unique = @($fingerprints | Select-Object -Unique)
    if ($unique.Count -eq 0) {
        return $null
    }
    if ($unique.Count -gt 1) {
        throw "ambiguous apksigner output: found $($unique.Count) different signer certificate SHA-256 digests ($($unique -join ', ')) -- refusing to guess which one is authoritative."
    }
    return $unique[0]
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

# Reads the SHA-256 fingerprint of the signer certificate of an APK, by
# shelling out to `apksigner verify --verbose --print-certs`. Throws if
# apksigner itself reports the APK as unverifiable, or if its output can't
# be parsed for a single, unambiguous fingerprint.
function Get-ApkCertFingerprint {
    param(
        [Parameter(Mandatory = $true)][string]$ApksignerPath,
        [Parameter(Mandatory = $true)][string]$ApkPath
    )
    # Captured as a raw line array rather than piped through Out-String, so
    # the parser sees apksigner's actual line breaks instead of console-
    # width-dependent re-wrapping that Out-String's default formatting can
    # introduce.
    $outputLines = @(& $ApksignerPath verify --verbose --print-certs $ApkPath 2>&1)
    $output = $outputLines -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        throw "apksigner verify failed for '$ApkPath' (exit code $LASTEXITCODE):`n$output"
    }
    $fingerprint = ConvertFrom-ApksignerCertOutput $output
    if ($null -eq $fingerprint) {
        throw "could not find a 'Signer ... certificate SHA-256 digest' line in apksigner output for '$ApkPath'. Raw apksigner output:`n$output"
    }
    return $fingerprint
}
