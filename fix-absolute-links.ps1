#
# fix-absolute-links.ps1
#
# Scan every HTML file under gameprogrammingpatterns.com/ and rewrite any
#   src="https://gameprogrammingpatterns.com/..."
#   href="https://gameprogrammingpatterns.com/..."
# to a relative path - but only when the target file exists locally.
# URLs whose target does not exist locally are left absolute
# (those are intentionally external or 404 on the server).
#
# Idempotent: running it repeatedly is safe.
#

$ErrorActionPreference = 'Stop'

$mirrorRoot = Join-Path $PSScriptRoot 'gameprogrammingpatterns.com'
if (-not (Test-Path -LiteralPath $mirrorRoot)) {
    Write-Host "Mirror root not found: $mirrorRoot" -ForegroundColor Yellow
    return
}
$absRoot = (Get-Item -LiteralPath $mirrorRoot).FullName

# Match src= or href= with an absolute https://gameprogrammingpatterns.com/ URL
$pattern = '(src|href)="https://gameprogrammingpatterns\.com/([^"]+)"'

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
    # Read as bytes to detect BOM, then decode as UTF-8
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
        $attr    = $m.Groups[1].Value
        $urlPath = $m.Groups[2].Value

        # Strip fragment / query for filesystem lookup
        $cleanPath = ($urlPath -split '[?#]')[0]

        # Compute target filesystem path
        $targetFsPath = Join-Path $absRoot ($cleanPath -replace '/', '\')
        if ($cleanPath.EndsWith('/')) {
            $targetFsPath = Join-Path $targetFsPath 'index.html'
        }

        if (Test-Path -LiteralPath $targetFsPath -PathType Leaf) {
            $relative = Get-RelativePath -From $sourceDir -To $targetFsPath
            $relative = $relative -replace '\\', '/'
            $script:fixed++
            $script:localFixed++
            return "$attr=`"$relative`""
        } else {
            $script:kept++
            return $m.Value
        }
    })

    if ($newContent -ne $content) {
        [System.IO.File]::WriteAllText($file.FullName, $newContent, $encoding)
        $modifiedFiles++
        $relPath = $file.FullName.Substring($absRoot.Length - 'gameprogrammingpatterns.com'.Length)
        Write-Host ("Fixed {0} link(s) in: {1}" -f $script:localFixed, $relPath) -ForegroundColor Green
    }
}

Write-Host ''
Write-Host ("Files modified: {0}" -f $modifiedFiles)                    -ForegroundColor Cyan
Write-Host ("URLs converted to relative: {0}" -f $script:fixed)         -ForegroundColor Cyan
Write-Host ("URLs kept absolute (no local target): {0}" -f $script:kept) -ForegroundColor Yellow
