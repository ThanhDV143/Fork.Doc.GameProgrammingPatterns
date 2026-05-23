#
# fix-absolute-links.ps1
#
# Scan every HTML file under gameprogrammingpatterns.com/ and rewrite any
#   src="https://gameprogrammingpatterns.com/..."
#   href="https://gameprogrammingpatterns.com/..."
#   src="/..."   (root-relative)
#   href="/..."  (root-relative)
# to a relative path - but only when the target file exists locally.
#
# Why root-relative matters: opening an HTML file from disk uses
# file:// protocol; root-relative URLs like /contents.html resolve
# to the filesystem root (D:\contents.html) which does not exist.
# They MUST be converted to relative paths for offline viewing.
#
# URLs whose target does not exist locally are left as-is
# (intentionally external or 404 on the server).
#
# Idempotent: running it repeatedly is safe.
#

$ErrorActionPreference = 'Stop'

$siteHost   = 'gameprogrammingpatterns.com'
$hostPrefix = "https://$siteHost"
$mirrorRoot = Join-Path $PSScriptRoot $siteHost
if (-not (Test-Path -LiteralPath $mirrorRoot)) {
    Write-Host "Mirror root not found: $mirrorRoot" -ForegroundColor Yellow
    return
}
$absRoot = (Get-Item -LiteralPath $mirrorRoot).FullName

# Captures attr (src/href) and the URL value
$pattern = '(?<attr>src|href)="(?<url>[^"]+)"'

function Get-RelativePath {
    param([string]$From, [string]$To)
    $from = $From.TrimEnd('\','/') -replace '/', '\'
    $to   = $To -replace '/', '\'
    $fromSegs = $from -split '\\'
    $toSegs   = $to   -split '\\'
    $i = 0
    while ($i -lt $fromSegs.Length -and $i -lt $toSegs.Length -and
           $fromSegs[$i] -ieq $toSegs[$i]) {
        $i++
    }
    $upCount = $fromSegs.Length - $i
    $parts = @()
    for ($j = 0; $j -lt $upCount; $j++) { $parts += '..' }
    for ($j = $i; $j -lt $toSegs.Length; $j++) { $parts += $toSegs[$j] }
    if ($parts.Count -eq 0) { return '.' }
    return ($parts -join '\')
}

$htmlFiles = Get-ChildItem -Path $mirrorRoot -Recurse -Filter *.html -File

$script:fixed = 0
$script:kept  = 0
$modifiedFiles = 0

foreach ($file in $htmlFiles) {
    $bytes  = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $encoding = if ($hasBom) {
        New-Object System.Text.UTF8Encoding($true)
    } else {
        New-Object System.Text.UTF8Encoding($false)
    }
    $content = $encoding.GetString($bytes)
    if ($hasBom -and $content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        $content = $content.Substring(1)
    }

    $sourceDir = $file.DirectoryName
    $script:localFixed = 0

    $newContent = [regex]::Replace($content, $pattern, {
        param($m)
        $attr = $m.Groups['attr'].Value
        $url  = $m.Groups['url'].Value

        # Skip non-fetchable schemes
        if ($url -match '^(data:|javascript:|mailto:|tel:|#|//)') {
            $script:kept++
            return $m.Value
        }

        # Split off fragment/query (preserve them on the relative form)
        $cleanUrl = $url
        $suffix   = ''
        $idx = $url.IndexOfAny([char[]]@('?','#'))
        if ($idx -ge 0) {
            $cleanUrl = $url.Substring(0, $idx)
            $suffix   = $url.Substring($idx)
        }

        $urlPath = $null
        if ($cleanUrl.StartsWith($hostPrefix + '/')) {
            # Absolute same-host URL
            $urlPath = $cleanUrl.Substring($hostPrefix.Length + 1)
        } elseif ($cleanUrl -eq $hostPrefix -or $cleanUrl -eq ($hostPrefix + '/')) {
            # Bare host URL -> homepage
            $urlPath = ''
        } elseif ($cleanUrl -match '^https?://') {
            # Absolute different-host URL -> leave alone
            $script:kept++
            return $m.Value
        } elseif ($cleanUrl.StartsWith('/')) {
            # Root-relative URL
            $urlPath = $cleanUrl.TrimStart('/')
        } else {
            # Document-relative URL - already relative; nothing to do
            $script:kept++
            return $m.Value
        }

        # Compute target filesystem path
        $targetFsPath = Join-Path $absRoot ($urlPath -replace '/', '\')
        if ($urlPath -eq '' -or $cleanUrl.EndsWith('/')) {
            $targetFsPath = Join-Path $targetFsPath 'index.html'
        }

        if (Test-Path -LiteralPath $targetFsPath -PathType Leaf) {
            $relative = Get-RelativePath -From $sourceDir -To $targetFsPath
            $relative = $relative -replace '\\', '/'
            $script:fixed++
            $script:localFixed++
            return "$attr=`"$relative$suffix`""
        } else {
            $script:kept++
            return $m.Value
        }
    })

    if ($newContent -ne $content) {
        [System.IO.File]::WriteAllText($file.FullName, $newContent, $encoding)
        $modifiedFiles++
        $relPath = $file.FullName.Substring($absRoot.Length - $siteHost.Length)
        Write-Host ("  Fixed {0} link(s) in: {1}" -f $script:localFixed, $relPath) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host ("  Files modified: {0}" -f $modifiedFiles)                    -ForegroundColor Cyan
Write-Host ("  URLs converted to relative: {0}" -f $script:fixed)         -ForegroundColor Cyan
Write-Host ("  URLs kept as-is (external/missing/skipped): {0}" -f $script:kept) -ForegroundColor DarkGray
