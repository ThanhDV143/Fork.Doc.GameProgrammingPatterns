#
# update.ps1 - Robust mirror pipeline for gameprogrammingpatterns.com
#
# 3 phases (each tolerant to failures from the previous):
#   1. Mirror download (wget --mirror, no --convert-links)
#   2. Scan local HTML for every src=/href= reference; for any whose
#      local target is missing, retry with wget. Loop until no
#      progress or max attempts.
#   3. Convert remaining absolute URLs (where target file exists
#      locally) to relative paths via fix-absolute-links.ps1.
#
# Idempotent: running it on a healthy mirror is a no-op.
# Self-healing: any file deleted/corrupted by wget's --mirror
# behaviour is re-downloaded in phase 2.
#

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$site         = 'https://gameprogrammingpatterns.com/'
$siteHost     = 'gameprogrammingpatterns.com'
$mirrorRoot   = Join-Path $PSScriptRoot $siteHost
$maxRetries   = 10
$urlListFile  = Join-Path $PSScriptRoot '.missing-urls.txt'
$fixScript    = Join-Path $PSScriptRoot 'fix-absolute-links.ps1'

function Write-Phase($title) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $title"  -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}

# Walk every local HTML, extract every src=/href= reference, resolve
# to a filesystem path, and report which ones do not exist on disk.
# Returns absolute URLs (suitable for wget --input-file).
function Get-MissingFiles {
    if (-not (Test-Path -LiteralPath $mirrorRoot)) { return @() }

    $missing    = New-Object 'System.Collections.Generic.HashSet[string]'
    $pattern    = '(?:src|href)="([^"]+)"'
    $hostPrefix = "https://$siteHost"
    $rootNorm   = (Get-Item -LiteralPath $mirrorRoot).FullName

    $htmlFiles = Get-ChildItem -Path $mirrorRoot -Recurse -Filter *.html -File
    foreach ($file in $htmlFiles) {
        $htmlDir = $file.DirectoryName
        $content = [System.IO.File]::ReadAllText($file.FullName)

        foreach ($m in [regex]::Matches($content, $pattern)) {
            $url = $m.Groups[1].Value
            if ([string]::IsNullOrEmpty($url)) { continue }

            $cleanUrl = ($url -split '[?#]')[0]
            if ($cleanUrl -match '^(data:|javascript:|mailto:|tel:|#|//)') { continue }
            if ([string]::IsNullOrEmpty($cleanUrl)) { continue }

            $localTarget = $null
            $absUrl      = $null

            if ($cleanUrl -match '^https?://') {
                if (-not $cleanUrl.StartsWith($hostPrefix)) { continue }
                $urlPath     = $cleanUrl.Substring($hostPrefix.Length).TrimStart('/')
                $absUrl      = $cleanUrl
                $localTarget = Join-Path $rootNorm ($urlPath -replace '/', '\')
            } else {
                try {
                    $resolved = [System.IO.Path]::GetFullPath(
                        (Join-Path $htmlDir ($cleanUrl -replace '/', '\'))
                    )
                } catch { continue }
                if (-not $resolved.StartsWith($rootNorm)) { continue }
                $localTarget = $resolved
                $relPart = $resolved.Substring($rootNorm.Length).TrimStart('\') -replace '\\', '/'
                $absUrl  = "$hostPrefix/$relPart"
            }

            if ($cleanUrl.EndsWith('/')) {
                $localTarget = Join-Path $localTarget 'index.html'
                if (-not $absUrl.EndsWith('/')) { $absUrl = "$absUrl/" }
            }

            if (-not (Test-Path -LiteralPath $localTarget -PathType Leaf)) {
                [void]$missing.Add($absUrl)
            }
        }
    }

    return @($missing) | Sort-Object
}

# wget options shared by both phases
$wgetBaseOpts = @(
    '--secure-protocol=auto',
    '--max-redirect=5',
    '--tries=10',
    '--timeout=30',
    '--waitretry=10',
    '--retry-connrefused',
    '--retry-on-http-error=429,500,502,503,504',
    '--wait=0.25',
    '--random-wait'
)

# ------------------------------------------------------------
# Phase 1 - mirror download
# ------------------------------------------------------------
Write-Phase 'Phase 1/3: Mirror download'

$mirrorOpts = @(
    '--mirror',
    '--page-requisites',
    '--no-parent',
    '--adjust-extension'
) + $wgetBaseOpts + @($site)

# Note: we deliberately omit --convert-links here. Phase 3 handles
# link conversion based on filesystem state, which is more reliable
# than wget's session-memory approach.
& wget.exe @mirrorOpts
$wgetExitCode = $LASTEXITCODE
Write-Host ''
Write-Host "wget exit code: $wgetExitCode" -ForegroundColor DarkGray

# ------------------------------------------------------------
# Phase 2 - verify + retry until complete
# ------------------------------------------------------------
Write-Phase 'Phase 2/3: Verify completeness + retry missing'

$previousSignature = $null
$lastMissingCount  = -1

for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    Write-Host ''
    Write-Host "Scan #$attempt - checking local mirror against HTML references..." -ForegroundColor White

    $missing = @(Get-MissingFiles)
    $lastMissingCount = $missing.Count

    if ($missing.Count -eq 0) {
        Write-Host '  All referenced files are present locally.' -ForegroundColor Green
        break
    }

    $signature = ($missing -join '|')
    if ($signature -eq $previousSignature) {
        Write-Host "  $($missing.Count) file(s) still missing after retry - no further progress." -ForegroundColor Yellow
        Write-Host '  These URLs are likely 404 on the server (intentionally external or retired pages).' -ForegroundColor Yellow
        break
    }
    $previousSignature = $signature

    Write-Host "  $($missing.Count) file(s) missing. Re-downloading via wget --input-file..." -ForegroundColor Yellow

    Set-Content -LiteralPath $urlListFile -Value $missing -Encoding utf8

    $retryOpts = @(
        '--input-file', $urlListFile,
        '--force-directories',
        '--no-clobber',
        '--adjust-extension',
        '--page-requisites'
    ) + $wgetBaseOpts

    & wget.exe @retryOpts
}

if (Test-Path -LiteralPath $urlListFile) {
    Remove-Item -LiteralPath $urlListFile -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# Phase 3 - convert absolute to relative URLs (where target exists)
# ------------------------------------------------------------
Write-Phase 'Phase 3/3: Convert absolute URLs to relative'

if (Test-Path -LiteralPath $fixScript -PathType Leaf) {
    & $fixScript
} else {
    Write-Host "fix-absolute-links.ps1 not found in $PSScriptRoot - skipping conversion." -ForegroundColor Yellow
}

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------
Write-Phase 'Summary'

$finalMissing = @(Get-MissingFiles)

if ($finalMissing.Count -eq 0) {
    Write-Host 'All referenced files present. Mirror is complete and links resolved.' -ForegroundColor Green
} else {
    Write-Host "$($finalMissing.Count) URL(s) point to files not available locally:" -ForegroundColor Yellow
    Write-Host '(These are tracked as absolute URLs in HTML - clicking them opens the live site.)' -ForegroundColor DarkGray
    $finalMissing | Select-Object -First 15 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }
    if ($finalMissing.Count -gt 15) {
        Write-Host "  ... and $($finalMissing.Count - 15) more." -ForegroundColor DarkGray
    }
}
