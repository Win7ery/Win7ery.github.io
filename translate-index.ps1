param(
    [string[]]$TargetFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$encoding = New-Object System.Text.UTF8Encoding($false)
$translationCache = @{}
Add-Type -AssemblyName System.Web

function Contains-Chinese {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [Regex]::IsMatch($Text, '[\u4e00-\u9fff]')
}

function Translate-Text {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($translationCache.ContainsKey($Text)) { return $translationCache[$Text] }
    $encoded = [System.Web.HttpUtility]::UrlEncode($Text)
    $url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=en&dt=t&q=$encoded"
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
            $json = $response.Content | ConvertFrom-Json
            $segments = foreach ($part in $json[0]) { $part[0] }
            $translated = -join $segments
            $translationCache[$Text] = $translated
            return $translated
        } catch {
            $delay = [Math]::Min(8, [Math]::Pow(2, $attempt))
            Start-Sleep -Seconds $delay
        }
    }
    throw "Failed to translate text: $Text"
}

function Translate-FrontLine {
    param([string]$Line)
    $result = [Regex]::Replace($Line, '"([^"]*)"', {
        param($m)
        $inner = $m.Groups[1].Value
        if (Contains-Chinese $inner) {
            return '"' + (Translate-Text $inner) + '"'
        }
        return $m.Value
    })
    $result = [Regex]::Replace($result, "'([^']*)'", {
        param($m)
        $inner = $m.Groups[1].Value
        if (Contains-Chinese $inner) {
            return "'" + (Translate-Text $inner) + "'"
        }
        return $m.Value
    })
    return $result
}

function Translate-BodyLine {
    param([string]$Line)
    if (-not (Contains-Chinese $Line)) {
        return $Line
    }
    $leadingMatch = [Regex]::Match($Line, '^\s*')
    $trailingMatch = [Regex]::Match($Line, '\s*$')
    $leading = $leadingMatch.Value
    $trailing = $trailingMatch.Value
    $coreLength = $Line.Length - $leading.Length - $trailing.Length
    if ($coreLength -le 0) {
        return $Line
    }
    $core = $Line.Substring($leading.Length, $coreLength)
    $translatedCore = Translate-Text $core
    return $leading + $translatedCore + $trailing
}

$targets = @()
if ($TargetFiles -and $TargetFiles.Count -gt 0) {
    foreach ($target in $TargetFiles) {
        if (Test-Path $target) {
            $targets += Get-Item $target
        } else {
            Write-Warning "Target file not found: $target"
        }
    }
} else {
    if (Test-Path 'categories') {
        $targets += Get-ChildItem -Path 'categories' -Recurse -Filter '_index.en.md'
    }
    if (Test-Path 'post') {
        $targets += Get-ChildItem -Path 'post' -Recurse -Filter 'index.en.md'
    }
}

foreach ($file in $targets) {
    $originalName = if ($file.Name -eq '_index.en.md') { '_index.md' } else { 'index.md' }
    $originalPath = Join-Path $file.DirectoryName $originalName
    if (-not (Test-Path $originalPath)) {
        Write-Warning "Missing original file for $($file.FullName)"
        continue
    }
    $lines = [System.IO.File]::ReadAllLines($originalPath, $encoding)
    if ($lines.Length -eq 0) {
        continue
    }
    $marker = $lines[0].Trim()
    if ($marker -ne '+++' -and $marker -ne '---') {
        Write-Warning "Unsupported front matter in $($originalPath)"
        continue
    }
    $closingIndex = -1
    for ($i = 1; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Trim() -eq $marker) {
            $closingIndex = $i
            break
        }
    }
    if ($closingIndex -lt 0) {
        Write-Warning "No closing marker in $($originalPath)"
        continue
    }

    $outputLines = New-Object System.Collections.Generic.List[string]
    $outputLines.Add($lines[0])
    for ($i = 1; $i -lt $closingIndex; $i++) {
        $outputLines.Add((Translate-FrontLine $lines[$i]))
    }
    $outputLines.Add($lines[$closingIndex])
    for ($i = $closingIndex + 1; $i -lt $lines.Length; $i++) {
        $outputLines.Add((Translate-BodyLine $lines[$i]))
    }
    [System.IO.File]::WriteAllLines($file.FullName, $outputLines, $encoding)
    Write-Host "Updated $($file.FullName)"
}
