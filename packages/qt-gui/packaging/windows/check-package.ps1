# Clean-host check of the Windows app folder, headless: with only Windows on PATH, switch-core.exe passes doctor
# and answers initialize, and switch.exe starts the bundled helper and gets RPC answers from it.
# usage: check-package.ps1 -Folder <app folder> [-Qt <Qt dir, for the offscreen platform plugin only>] [-InPlace]
# Without -InPlace the folder is first copied to a new temporary folder, which proves it does not depend on its path.
param(
  [Parameter(Mandatory)] [string] $Folder,
  [string] $Qt = "C:\Qt\6.10.3\msvc2022_64",
  [switch] $InPlace
)
$ProgressPreference = "SilentlyContinue"
$work = Join-Path $env:TEMP ("switch-check-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
$app = if ($InPlace) { $Folder } else { Copy-Item -Recurse $Folder "$work\app"; "$work\app" }
$failed = 0

# The package ships only the "windows" platform; the headless run loads "offscreen" from outside the folder.
New-Item -ItemType Directory -Force "$work\platforms" | Out-Null
Copy-Item "$Qt\plugins\platforms\qoffscreen.dll" "$work\platforms\"
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
Remove-Item Env:QML2_IMPORT_PATH, Env:QML_IMPORT_PATH, Env:QT_PLUGIN_PATH, Env:SWITCH_CORE -ErrorAction SilentlyContinue

"== switch-core doctor"
& "$app\switch-core.exe" doctor --root "$work\doctor" | Select-Object -Last 1
if ($LASTEXITCODE -ne 0) { "doctor FAILED, exit $LASTEXITCODE"; $failed++ }

"== switch-core serve: initialize"
$reply = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' |
  & "$app\switch-core.exe" serve --root "$work\serve" 2>$null | Select-Object -First 1
if ($reply -match '"result"') { "initialize ok" } else { "initialize FAILED: $reply"; $failed++ }

"== switch.exe, offscreen, 20 s"
$env:QT_QPA_PLATFORM = "offscreen"
$env:QT_QPA_PLATFORM_PLUGIN_PATH = "$work\platforms"
$env:QT_FORCE_STDERR_LOGGING = "1"
$env:QT_LOGGING_RULES = "switch.helper.info=true"
$p = Start-Process -FilePath "$app\switch.exe" -ArgumentList "--root", "`"$work\app-root`"" -PassThru -NoNewWindow `
  -RedirectStandardError "$work\app.err" -RedirectStandardOutput "$work\app.out"
Start-Sleep -Seconds 20
# Get-Process, not WMI: a standard user may not query WMI.
$helper = Get-Process switch-core -ErrorAction SilentlyContinue | Where-Object Path -eq "$app\switch-core.exe"
$running = -not $p.HasExited
if ($running) { Stop-Process -Id $p.Id -Force; $p.WaitForExit() }
Start-Sleep -Seconds 2
$ok = @(Select-String -Path "$work\app.err" -Pattern '^switch\.helper: rpc .* ok$').Count
"running after 20 s: $running; helper: $($helper.Path); rpc answers ok: $ok"
if (-not $running -or -not $helper -or $ok -lt 3) {
  Get-Content "$work\app.err" | Select-Object -Last 15
  $failed++
}
$left = Get-Process switch-core -ErrorAction SilentlyContinue | Where-Object Path -like "$app\*"
if ($left) { "helper still running after the app stopped"; $left | Stop-Process -Force; $failed++ }

# Every page in demo mode: a missing QML module or plugin fails that page's Loader, and the app logs it.
$bad = 'failed to load|is not installed|Cannot load library|plugin cannot be loaded'
foreach ($page in "Overview", "Accounts", "Settings", "Maintenance", "History") {
  $p = Start-Process -FilePath "$app\switch.exe" -ArgumentList "--demo", "--page", $page -PassThru -NoNewWindow `
    -RedirectStandardError "$work\page.err" -RedirectStandardOutput "$work\page.out"
  Start-Sleep -Seconds 8
  $running = -not $p.HasExited
  if ($running) { Stop-Process -Id $p.Id -Force; $p.WaitForExit() }
  $errors = @(Select-String -Path "$work\page.err" -Pattern $bad)
  "page ${page}: running $running, load errors $($errors.Count)"
  if (-not $running -or $errors) { $errors | Select-Object -First 5 | ForEach-Object { "  $($_.Line)" }; $failed++ }
}

# The folder dialog's non-native form (the offscreen platform has no native one) loads Quick Controls, which the
# package trims to Basic. Qt's qml tool goes into the test copy so it sees only the package's modules.
if (-not $InPlace) {
  Copy-Item "$Qt\bin\qml.exe" $app
  Set-Content "$work\dialog.qml" @'
import QtQuick
import QtQuick.Dialogs
Window {
  width: 800; height: 600; visible: true
  FolderDialog { id: dialog; title: "probe" }
  Timer { interval: 300; running: true; onTriggered: dialog.open() }
  Timer { interval: 3000; running: true; onTriggered: { console.log("DIALOG visible=" + dialog.visible); Qt.quit() } }
}
'@
  $env:QT_QUICK_CONTROLS_STYLE = "Basic"
  $p = Start-Process -FilePath "$app\qml.exe" -ArgumentList "`"$work\dialog.qml`"" -PassThru -NoNewWindow -Wait `
    -RedirectStandardError "$work\dialog.err" -RedirectStandardOutput "$work\dialog.out"
  $shown = Select-String -Path "$work\dialog.err", "$work\dialog.out" -Pattern 'DIALOG visible=true' -Quiet
  $errors = @(Select-String -Path "$work\dialog.err" -Pattern $bad)
  "folder dialog (Basic): shown $shown, load errors $($errors.Count)"
  if (-not $shown -or $errors) { Get-Content "$work\dialog.err" | Select-Object -Last 8; $failed++ }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
if ($failed) { "check FAILED ($failed)"; exit 1 }
"check passed"
exit 0
