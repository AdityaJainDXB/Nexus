; Nexus for Windows — Inno Setup script
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\Nexus"
#endif

[Setup]
AppId={{6F3C2B7A-8E4D-4A21-9C1B-4E58A0D3F7B2}
AppName=Nexus
AppVersion={#AppVersion}
AppVerName=Nexus {#AppVersion}
AppPublisher=Nexus
AppPublisherURL=https://github.com/AdityaJainDXB/Nexus
AppSupportURL=https://github.com/AdityaJainDXB/Nexus/issues
DefaultDirName={autopf}\Nexus
DefaultGroupName=Nexus
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=Nexus-Setup-{#AppVersion}-x64
SetupIconFile=..\src\Nexus.App\Assets\nexus.ico
UninstallDisplayIcon={app}\Nexus.exe
Compression=lzma2/fast
SolidCompression=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
MinVersion=10.0.17763
CloseApplications=force
LicenseFile=..\..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start Nexus when I sign in (recommended)"; GroupDescription: "Startup:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Nexus"; Filename: "{app}\Nexus.exe"
Name: "{autodesktop}\Nexus"; Filename: "{app}\Nexus.exe"; Tasks: desktopicon

[Registry]
; nexus:// links (widgets, scripts, Shortcuts-style automation)
Root: HKA; Subkey: "Software\Classes\nexus"; ValueType: string; ValueData: "URL:Nexus"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\nexus"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\nexus\DefaultIcon"; ValueType: string; ValueData: """{app}\Nexus.exe"",0"
Root: HKA; Subkey: "Software\Classes\nexus\shell\open\command"; ValueType: string; ValueData: """{app}\Nexus.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Nexus"; ValueData: """{app}\Nexus.exe"" --background"; Tasks: startup; Flags: uninsdeletevalue

[Run]
; iPhone Remote: allow Nexus on private networks only (skipped for per-user installs)
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""Nexus Remote"" dir=in action=allow program=""{app}\Nexus.exe"" profile=private enable=yes"; Flags: runhidden; Check: IsAdminInstallMode
Filename: "{app}\Nexus.exe"; Description: "Launch Nexus"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM Nexus.exe"; Flags: runhidden; RunOnceId: "KillNexus"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM llama-server.exe"; Flags: runhidden; RunOnceId: "KillLlama"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""Nexus Remote"""; Flags: runhidden; Check: IsAdminInstallMode; RunOnceId: "DelFirewall"
