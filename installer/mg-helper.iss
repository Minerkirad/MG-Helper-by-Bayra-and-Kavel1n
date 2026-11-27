; MG Helper 3.1 - Inno Setup script (packaging, ярлыки, uninstall).
; Собирается tools\package-release.ps1, если на машине есть ISCC.exe (Inno Setup 6+).
; Задача: поставить приложение в %LOCALAPPDATA%\MG_Helper\App\Versions\<ver> и обновить
; current.json, не трогая пользовательские данные в DataRoot.

#define AppName "MG Helper"
#define AppPublisher "Bayra & Kavel1n"
#define AppExe "MGHelper.exe"
#ifndef AppVersion
  #define AppVersion "3.1.0"
#endif
#ifndef StageDir
  #define StageDir "..\release\stage"
#endif

[Setup]
AppId={{8F3B2C21-4E1B-4C55-9E52-6D2B0C7A9A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\MG_Helper\App\Versions\{#AppVersion}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\release
OutputBaseFilename=MG-Helper-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\ui\assets\mghelper.ico
UninstallDisplayIcon={app}\{#AppExe}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; подпись Setup выполняется tools\sign.ps1 после компиляции

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Ярлык на рабочем столе"; GroupDescription: "Ярлыки:"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Run]
Filename: "{app}\MGHelper.exe"; Description: "Запустить {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN MG_Helper_Watcher"; Flags: runhidden; RunOnceId: "stopwatcher"