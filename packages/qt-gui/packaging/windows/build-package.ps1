# Builds the Windows app folder that switch.iss installs: switch.exe and switch-core.exe, the Qt files windeployqt
# finds, the Swift runtime DLLs that switch-core.exe imports (followed recursively), and the MSVC runtime DLLs
# app-local, so a per-user install needs no administrator rights. Run it where MSVC, Qt, and Swift are installed.
# usage: build-package.ps1 -App <switch.exe> -Core <release switch-core.exe> -QmlDir <qt-gui\qml> -Out <folder>
#        [-Qt <Qt msvc2022_64 dir>] [-SwiftRuntime <dir with swiftCore.dll>] [-VcVars <vcvars64.bat>]
param(
  [Parameter(Mandatory)] [string] $App,
  [Parameter(Mandatory)] [string] $Core,
  [Parameter(Mandatory)] [string] $QmlDir,
  [Parameter(Mandatory)] [string] $Out,
  [string] $Qt = "C:\Qt\6.10.3\msvc2022_64",
  [string] $SwiftRuntime = "",
  [string] $VcVars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $SwiftRuntime) {
  $found = Get-Command swiftCore.dll -ErrorAction SilentlyContinue
  if (-not $found) { throw "swiftCore.dll is not on PATH; pass -SwiftRuntime" }
  $SwiftRuntime = Split-Path $found.Source
}

# DLL names a set of PE files import, from dumpbin in a Visual Studio environment (30 files per call: cmd line limit).
function Get-Imports([string[]] $Files) {
  $names = @()
  for ($i = 0; $i -lt $Files.Count; $i += 30) {
    $batch = ($Files[$i..([math]::Min($i + 29, $Files.Count - 1))] | ForEach-Object { "`"$_`"" }) -join " "
    $out = cmd.exe /c "`"$VcVars`" >nul && dumpbin /nologo /dependents $batch"
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed" }
    $names += $out | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[\w.+-]+\.dll$' }
  }
  $names | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique
}

if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $Out | Out-Null
Copy-Item $App (Join-Path $Out "switch.exe")
Copy-Item $Core (Join-Path $Out "switch-core.exe")

# The folder carries the MSVC runtime itself (below), so windeployqt does not add vc_redist. Its warnings go to
# stderr, which "Stop" would turn into an error when the caller redirects it; the exit code decides.
$ErrorActionPreference = "Continue"
& "$Qt\bin\windeployqt.exe" --release --no-compiler-runtime --no-translations --qmldir $QmlDir (Join-Path $Out "switch.exe") 2>&1 |
  Where-Object { "$_" -match 'Warning|Error' } | ForEach-Object { "windeployqt: $_" }
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed" }

# Only the Swift runtime DLLs switch-core.exe needs: follow imports until no new one appears.
$queue = @((Join-Path $Out "switch-core.exe"))
$copied = @{}
while ($queue.Count -gt 0) {
  $next = @()
  foreach ($name in Get-Imports $queue) {
    $source = Join-Path $SwiftRuntime $name
    if ($copied.ContainsKey($name) -or -not (Test-Path $source)) { continue }
    Copy-Item $source $Out
    $copied[$name] = $true
    $next += Join-Path $Out $name
  }
  $queue = $next
}
"swift runtime: $($copied.Count) DLLs ($(($copied.Keys | Sort-Object) -join ', '))"

# Every PE file in the folder; MSVC runtime DLLs any of them imports come from Visual Studio's redist folder.
$pe = Get-ChildItem $Out -Recurse -File -Include *.exe, *.dll | ForEach-Object FullName
$imports = Get-Imports $pe
$crtNames = $imports | Where-Object { $_ -match '^(vcruntime|msvcp|concrt|vccorlib)\d' }
if ($crtNames) {
  # vcvars64.bat sits in <VS>\VC\Auxiliary\Build; the redist folders are <VS>\VC\Redist\MSVC\<version>\x64.
  $vc = Split-Path (Split-Path (Split-Path $VcVars))
  $crt = Get-ChildItem "$vc\Redist\MSVC\*\x64\Microsoft.VC*.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
  if (-not $crt) { throw "no Microsoft.VC*.CRT folder under $vc\Redist\MSVC" }
  foreach ($name in $crtNames) {
    $source = Join-Path $crt.FullName $name
    if (-not (Test-Path $source)) { throw "$name is imported but not in $($crt.FullName)" }
    Copy-Item $source $Out
  }
  "msvc runtime: $($crtNames -join ', ') from $($crt.Name)"
}

# Each import must be in the folder or be a Windows system DLL.
$missing = $imports | Where-Object {
  -not (Test-Path (Join-Path $Out $_)) -and -not (Test-Path (Join-Path "$env:SystemRoot\System32" $_)) -and $_ -notmatch '^(api|ext)-ms-'
}
if ($missing) { throw "imports not in the folder or System32: $($missing -join ', ')" }
$files = Get-ChildItem $Out -Recurse -File
"package: $Out, $($files.Count) files, $([math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB, 1)) MB"
