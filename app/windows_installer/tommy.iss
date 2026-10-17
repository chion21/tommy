; Inno Setup script → TommySetup.exe (customer just clicks Next → Install)
#define AppName "Tommy"
#define AppVersion "0.3.0"
[Setup]
AppId={{40CA4EB4-50A0-4123-B5A9-5E745912CF77}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Tommy AI
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=..\build\installer
OutputBaseFilename=TommySetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
[Tasks]
Name: "desktopicon"; Description: "Desktop shortcut"; Flags: checkedonce
Name: "autostart"; Description: "Start with Windows"; Flags: unchecked
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\tommy.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\tommy.exe"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\tommy.exe"; Tasks: autostart
[Run]
Filename: "{app}\tommy.exe"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
