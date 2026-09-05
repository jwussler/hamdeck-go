; Windows installer for the HamDeck panel.
;
; ⚠️ THIS EXISTS BECAUSE A ZIP IS NOT A DELIVERABLE. Handing somebody a zip asks
; them to find an exe among a few hundred files and make their own shortcut.
; Nobody does that, and the ones who try pick the wrong file. Every platform gets
; a real package: this on Windows, a .dmg on macOS, a .deb on Linux.
;
; ⚠️ PER-USER, NO ADMIN PROMPT. It installs into LocalAppData deliberately -
; asking for elevation to run a radio panel is friction with nothing behind it.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\client\build\windows\x64\runner\Release"
#endif

[Setup]
; ⚠️ A DIFFERENT AppId FROM THE C++ CLIENT. Sharing one would make installing
; this uninstall that, and an operator who wanted both would silently lose the
; one that works today.
AppId={{2B9F41A6-7C3D-4E58-9D21-8A6E4F0B5C77}
AppName=HamDeck Panel
AppVersion={#AppVersion}
AppVerName=HamDeck Panel {#AppVersion}
AppPublisher=WA0O
AppPublisherURL=https://hamdeck.io
DefaultDirName={localappdata}\HamDeck Panel
DefaultGroupName=HamDeck
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir=.
OutputBaseFilename=HamDeck-Panel-Windows-Setup
UninstallDisplayIcon={app}\hamdeck_panel.exe
; ⚠️ THE MARK, EVERYWHERE THE OPERATOR SEES ONE. This was missed on every build
; so far: the app shipped with FLUTTER'S OWN LOGO as its icon, so the taskbar,
; the Start menu and Add/Remove Programs all showed a stranger's product. The
; installer had no icon at all. Asked for repeatedly; the check in tools/
; preflight.sh is what stops it going missing again.
SetupIconFile=branding\hamdeck.ico
WizardSmallImageFile=branding\wizard-small.bmp
UninstallDisplayName=HamDeck Panel
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
; ⚠️ The whole staged tree, recursively. The panel is useless without its Flutter
; runtime and the two native audio plugins - flutter_soloud_plugin.dll and
; record_windows_plugin.dll. Their absence does not stop it starting; it starts
; fine and silently has no audio in either direction, which is far worse.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "branding\hamdeck.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; IconFilename is explicit so a shortcut shows the mark even before the exe's own
; resource is read.
Name: "{group}\HamDeck Panel"; Filename: "{app}\hamdeck_panel.exe"; IconFilename: "{app}\hamdeck.ico"
Name: "{userdesktop}\HamDeck Panel"; Filename: "{app}\hamdeck_panel.exe"; IconFilename: "{app}\hamdeck.ico"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\hamdeck_panel.exe"; Description: "Start HamDeck Panel"; Flags: nowait postinstall skipifsilent
