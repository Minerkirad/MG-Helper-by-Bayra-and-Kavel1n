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
; финализация: переключить current.json, обновить скрипты в DataRoot, автозапуск, старт приложения
Filename: "{app}\MGHelper.exe"; Parameters: "--install-finalize"; Flags: runhidden waituntilterminated; StatusMsg: "Настраиваю MG Helper (версия, автозапуск)…"

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN MG_Helper_Watcher"; Flags: runhidden; RunOnceId: "stopwatcher"
[Code]
{ Проверка .NET Framework 4.8: приложение на нём работает, без него установка бессмысленна. }
function InitializeSetup(): Boolean;
var
  Release: Cardinal;
  Found: Boolean;
begin
  Result := True;
  Found := RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release);
  if not Found then
    Found := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release);
  if not Found or (Release < 528040) then
  begin
    MsgBox('Для MG Helper нужен .NET Framework 4.8 или новее.' + #13#10 + #13#10 +
           'Он уже входит в Windows 10 (обновление 1903 и новее) и Windows 11.' + #13#10 +
           'Установите обновление Windows или .NET Framework 4.8 с сайта Microsoft и повторите установку.' + #13#10 + #13#10 +
           'Ваши файлы настроек и эталон не затронуты.',
           mbError, MB_OK);
    Result := False;
  end;
end;
