; Установщик Nexus Nimbus (Windows).
;
; Упаковывает release-сборку Flutter в один NexusNimbus-Setup-X.Y.Z.exe,
; который WinSparkle умеет запустить тихо и обновить программу на месте.
;
; Вид мастера — стандартный для Inno Setup. Своя тут только иконка:
; попытка перекрасить мастер в палитру приложения обходится дорого
; (каждый орган управления красится вручную, кнопки и полосу выполнения
; приходится подменять своими), а выглядит всё равно чужеродно рядом
; с системными диалогами Windows.
;
; Сборка:
;   1. flutter build windows --release
;   2. Inno Setup 6 (%LOCALAPPDATA%\Programs\Inno Setup 6)
;   3. ISCC.exe dist\installer.iss /DAppVersion=0.3.0
;   Проще одной командой: dist\release.ps1 -Version 0.3.0
;
; Результат: dist\out\NexusNimbus-Setup-<версия>.exe

#ifndef AppVersion
  #define AppVersion "0.3.0"
#endif

#define MyAppName "Nexus Nimbus"
#define MyAppExeName "nexus_nimbus.exe"
#define MyAppPublisher "Nexus"
#define MyAppUrl "https://github.com/kekw2077/nexus-nimbus"

; Постоянный GUID обновления. Менять нельзя: по нему Windows понимает, что
; новая версия заменяет старую, а не ставится второй программой рядом.
#define MyAppId "{{B7F41C6E-2A9D-4E58-9C11-6E0A3D5B84F2}"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppVerName={#MyAppName} {#AppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppUrl}
AppSupportURL={#MyAppUrl}
AppUpdatesURL={#MyAppUrl}
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=out
OutputBaseFilename=NexusNimbus-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

; Иконка приложения — она же у мастера, у ярлыков и в «Установке и удалении».
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

; Обновление ставится молча, поверх той копии, что уже стоит. Путь берётся
; из реестра прошлой установки — поэтому именно yes, а не no: /DIR мы не
; передаём, и без этой строки тихое обновление ушло бы в Program Files
; мимо копии, которой человек пользуется, и рядом появилась бы вторая.
UsePreviousAppDir=yes

; Пользователь выбирает сам: «только для меня» (без UAC, тихие обновления
; проходят без запроса прав) или «для всех» в Program Files. По умолчанию
; первое — на семейных машинах так меньше поводов для окна UAC.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline

; Если программа запущена, закрыть её через Restart Manager, а не падать.
CloseApplications=force
RestartApplications=no

; AppMutex здесь БЫЛ и был убран намеренно.
;
; По мьютексу Setup узнавал запущенную копию — но проверка эта срабатывает
; раньше Restart Manager и умеет только показать «закройте программу».
; В тихом режиме показывать некому, и установка прекращалась с кодом 1,
; ничего не сделав. То есть мьютекс ломал ровно тот случай, ради которого
; тихое обновление и заведено: обновление поверх работающей программы.
;
; Закрывать запущенную копию умеет CloseApplications=force выше — ему
; мьютекс не нужен, он ищет процессы по занятым файлам. Сам мьютекс в
; приложении остаётся (windows/runner/main.cpp), он там для другого:
; чтобы второй запуск ярлыка поднимал уже открытое окно.

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Вся release-сборка Flutter: exe, движок, data\ и DLL плагинов.
; Отладочные символы в установщик не кладём — это несколько десятков МБ,
; которые пришлось бы качать при каждом обновлении.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; \
  Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Обычная установка: предложить запустить в конце.
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; \
  Flags: nowait postinstall skipifsilent
; Тихое обновление: поднять новую версию само (/RELAUNCH=1), чтобы выглядело
; как обычный перезапуск.
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: ShouldRelaunch

[Code]
{ Тихое обновление запускает установщик с /RELAUNCH=1 и выходит; после
  установки новая версия поднимается сама. }
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;
