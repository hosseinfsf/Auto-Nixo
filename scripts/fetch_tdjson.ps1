# fetch_tdjson.ps1
#
# Downloads the TDLib tdjson.dll for Windows into the engine directory so the
# FFI wrapper (apps/engine/lib/src/telegram/tdlib_client.dart) can load it.
#
# The DLL is NEVER committed to git (see .gitignore). Run this on the owner's
# Windows PC before building/running the engine.
#
# Allowed sources (choose one):
#   1. ivk1800/td-json-client-prebuilt GitHub Releases
#   2. npm package "prebuilt-tdlib"
#   3. a build of TDLib from source (github.com/tdlib/td)
#
# IMPORTANT: pin a version and record its SHA256 here once the owner chooses a
# source. The current script is a template and does NOT yet pin a version.

param(
    [string]$Source = "github",   # "github" | "npm" | "local"
    [string]$Version = "",         # e.g. "1.8.0"
    [string]$OutDir = "apps/engine/lib/src/telegram/bin"
)

$ErrorActionPreference = "Stop"
$OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) $OutDir
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Dll = Join-Path $OutDir "tdjson.dll"

switch ($Source) {
    "github" {
        if (-not $Version) { throw "github source requires -Version (e.g. 1.8.0)" }
        $Url = "https://github.com/ivk1800/td-json-client-prebuilt/releases/download/$Version/tdjson.dll"
        Write-Host "Downloading tdjson.dll from $Url"
        Invoke-WebRequest -Uri $Url -OutFile $Dll -UseBasicParsing
    }
    "npm" {
        if (-not $Version) { $Version = "latest" }
        Write-Host "Fetching prebuilt-tdlib@$Version from npm"
        $tmp = Join-Path $env:TEMP "tdlib-npm-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Push-Location $tmp
        try {
            npm pack "prebuilt-tdlib@$Version" | Out-Null
            $tgz = Get-ChildItem -Filter "*.tgz" | Select-Object -First 1
            tar -xzf $tgz.FullName
            Copy-Item "package/build/Release/tdjson.dll" $Dll -Force
        } finally {
            Pop-Location
            Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
        }
    }
    "local" {
        if (-not (Test-Path $OutDir)) { throw "local source requires a prebuilt tdjson.dll path" }
        Write-Host "Using local tdjson.dll"
    }
    default { throw "Unknown source '$Source' (use github|npm|local)" }
}

if (Test-Path $Dll) {
    $hash = (Get-FileHash $Dll -Algorithm SHA256).Hash
    Write-Host "tdjson.dll ready at $Dll"
    Write-Host "SHA256: $hash"
    Write-Host "RECORD this SHA256 in DECISIONS.md and pin the version."
} else {
    throw "tdjson.dll was not produced."
}
