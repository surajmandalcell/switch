; Per-user Windows installer (Inno Setup 6) for the folder build-package.ps1 makes. No administrator rights:
; the app goes to %LOCALAPPDATA%\Programs\Switch and the MSVC runtime is app-local in that folder.
; usage: ISCC.exe /DSourceDir=<app folder> /DAppVersion=<x.y.z> /O<output folder> switch.iss
; Uninstall removes the program files, the Start menu entry, and the login item; the data root stays.

#ifndef SourceDir
  #error Pass /DSourceDir=<app folder from build-package.ps1>
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

[Setup]
; Never change AppId: upgrades and the uninstaller find the installed app by it.
AppId={{5EFE32C8-F5A5-4E08-86E1-48E206ED6D47}
AppName=Switch
AppVersion={#AppVersion}
AppVerName=Switch {#AppVersion}
DefaultDirName={autopf}\Switch
DefaultGroupName=Switch
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputBaseFilename=Switch-{#AppVersion}-setup
UninstallDisplayIcon={app}\switch.exe
UninstallDisplayName=Switch
CloseApplications=force
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Switch"; Filename: "{app}\switch.exe"

[Registry]
; The app writes this login item itself (Settings, Open at login); uninstall removes it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "Switch"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\switch.exe"; Description: "Open Switch"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; A running app or helper would keep its files; stop only processes started from this folder ("{{" is a literal "{").
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -Command ""Get-CimInstance Win32_Process | Where-Object {{ $_.ExecutablePath -like '{app}\*' } | ForEach-Object {{ Stop-Process -Id $_.ProcessId -Force }"""; Flags: runhidden waituntilterminated; RunOnceId: "StopApp"
