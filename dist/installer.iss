; Установщик Nexus Nimbus (Windows).
;
; Упаковывает release-сборку Flutter в один NexusNimbus-Setup-X.Y.Z.exe,
; который WinSparkle (auto_updater) умеет запустить тихо и обновить программу
; на месте.
;
; Сборка:
;   1. flutter build windows --release
;   2. Inno Setup 6 (%LOCALAPPDATA%\Programs\Inno Setup 6)
;   3. ISCC.exe dist\installer.iss /DAppVersion=0.1.0
;   Проще одной командой: dist\release.ps1 -Version 0.1.0
;
; Результат: dist\out\NexusNimbus-Setup-<версия>.exe

#ifndef AppVersion
  #define AppVersion "0.1.0"
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
DisableWelcomePage=no
OutputDir=out
OutputBaseFilename=NexusNimbus-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Тихое обновление из приложения передаёт /DIR="<папка запущенной копии>",
; чтобы перезаписать именно ту копию, которой пользуются. Без этого Inno взял
; бы путь из реестра от прошлой установки и молча проигнорировал /DIR —
; запущенная копия осталась бы старой, а обновление зациклилось.
UsePreviousAppDir=no

; Пользователь выбирает сам: «только для меня» (без UAC, тихие обновления
; проходят без запроса прав) или «для всех» в Program Files. По умолчанию
; первое — на семейных машинах так меньше поводов для окна UAC.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline

; Если программа запущена, закрыть её через Restart Manager, а не падать.
CloseApplications=force
RestartApplications=no
; Тот же мьютекс, что держит приложение (windows/runner/main.cpp).
; Два написания двигаются только вместе.
AppMutex=NexusNimbus-SingleInstance-Mutex

; Стиль ТОЛЬКО classic. В modern мастер рисует фон страниц сам и заданный
; Color игнорирует: окно остаётся белым, а покрашенный светлый текст на нём
; становится нечитаемым. Проверено — не меняйте на modern.
WizardStyle=classic
WizardImageFile=wizard-banner.bmp
WizardSmallImageFile=wizard-small.bmp
WizardImageStretch=no

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

; Подложки кнопок мастера. dontcopy — файлы нужны только самому мастеру,
; в установленную программу они не попадают.
Source: "btn_primary.bmp"; Flags: dontcopy
Source: "btn_quiet.bmp"; Flags: dontcopy

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
{ ------------------------------------------------------------------------
  Оформление Prism.

  Inno рисует мастер стандартными органами управления Windows, поэтому
  «тёмная тема» здесь — это перекраска каждого из них вручную. Красится всё,
  кроме двух вещей, которые рисует сама система и достать до них нельзя:
  рамка окна с заголовком и запрос UAC при установке «для всех».

  Полоса выполнения и кнопки заменены своими: у стандартных цвет задаётся
  темой Windows и свойством Color не меняется.
  ------------------------------------------------------------------------ }

const
  { TColor в Inno — это $00BBGGRR, порядок байтов обратный привычному HTML. }
  clBg        = $000C0807;  { #07080C  фон окна            }
  clSolid     = $00191311;  { #111319  плотная подложка     }
  clHeader    = $00110C0B;  { #0B0C11  полоса шапки         }
  clField     = $00140F0E;  { поле ввода                    }
  clChip      = $001E1A18;  { дорожка полосы выполнения     }
  clStroke    = $0027201F;  { тонкая рамка                  }
  clTxt       = $00F8F4F2;  { #F2F4F8  заголовки            }
  clBody      = $00D6CBC7;  { #C7CBD6  основной текст       }
  clSub       = $00A69993;  { #9399A6  подписи              }
  clFaint     = $00796C66;  { #666C79  третьестепенное      }
  clAccent    = $00D1633F;  { #3F63D1  акцент               }

var
  ProgressTrack: TPanel;
  ProgressFill: TPanel;
  BtnBackImg, BtnNextImg, BtnCancelImg: TBitmapImage;
  BtnBackLbl, BtnNextLbl, BtnCancelLbl: TLabel;

{ Тихое обновление запускает установщик с /RELAUNCH=1 и выходит; после
  установки новая версия поднимается сама. }
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;

{ Подписи мастера — это TNewStaticText, а не TLabel: свойства Color у них нет,
  фон они берут у страницы. Красим только шрифт. }
procedure PaintText(S: TNewStaticText; Color: TColor; Size: Integer; Bold: Boolean);
begin
  { Каждый шаг обёрнут отдельно намеренно. Набор органов управления у мастера
    зависит от стиля и от того, какие страницы вообще включены; один
    неподдержанный элемент не должен оборвать покраску всего остального —
    иначе получается наполовину тёмное окно с нечитаемым текстом. }
  try
    if S = nil then Exit;
    S.Font.Name := 'Segoe UI';
    S.Font.Color := Color;
    if Size > 0 then S.Font.Size := Size;
    if Bold then S.Font.Style := [fsBold] else S.Font.Style := [];
  except
  end;
end;

{ Страницы мастера держат свой цвет и от формы его не наследуют — у Inno
  они белые по умолчанию. Красить надо каждую: непокрашенная останется
  белым пятном ровно на том шаге, до которого дошёл пользователь.
  А вот у самого TNewNotebook свойства Color нет — только у страниц. }
procedure PaintPage(P: TNewNotebookPage);
begin
  try
    if P <> nil then P.Color := clBg;
  except
  end;
end;

{ Клик по своей кнопке просто передаётся стандартной — вся логика мастера
  остаётся на месте, меняется только внешний вид. }
procedure OnBackClick(Sender: TObject);
begin
  if WizardForm.BackButton.Enabled then WizardForm.BackButton.OnClick(WizardForm.BackButton);
end;

procedure OnNextClick(Sender: TObject);
begin
  if WizardForm.NextButton.Enabled then WizardForm.NextButton.OnClick(WizardForm.NextButton);
end;

procedure OnCancelClick(Sender: TObject);
begin
  if WizardForm.CancelButton.Enabled then WizardForm.CancelButton.OnClick(WizardForm.CancelButton);
end;

procedure MakeButton(Native: TNewButton; Primary: Boolean;
  var Img: TBitmapImage; var Lbl: TLabel; Handler: TNotifyEvent);
var
  Bmp: String;
begin
  if Primary then Bmp := 'btn_primary.bmp' else Bmp := 'btn_quiet.bmp';
  ExtractTemporaryFile(Bmp);

  Img := TBitmapImage.Create(WizardForm);
  Img.Parent := Native.Parent;
  Img.SetBounds(Native.Left, Native.Top, Native.Width, Native.Height);
  Img.Bitmap.LoadFromFile(ExpandConstant('{tmp}\') + Bmp);
  Img.Stretch := True;
  Img.Cursor := crHandPoint;
  Img.OnClick := Handler;

  Lbl := TLabel.Create(WizardForm);
  Lbl.Parent := Native.Parent;
  Lbl.SetBounds(Native.Left, Native.Top + (Native.Height div 2) - 8, Native.Width, 16);
  Lbl.Alignment := taCenter;
  Lbl.AutoSize := False;
  Lbl.Transparent := True;
  Lbl.Cursor := crHandPoint;
  Lbl.OnClick := Handler;
  Lbl.Font.Name := 'Segoe UI';
  Lbl.Font.Size := 9;
  Lbl.Font.Style := [fsBold];
  Lbl.Font.Color := clTxt;
  Lbl.Caption := Native.Caption;

  { Стандартную кнопку не удаляем: на ней держится вся логика мастера,
    включая клавиатуру. Просто убираем её с глаз. }
  Native.Width := 0;
  Native.Height := 0;
end;

{ Подписи и доступность стандартных кнопок меняются от страницы к странице —
  переносим их на свои при каждом переходе. }
procedure SyncButtons;
begin
  if BtnNextLbl = nil then Exit;

  BtnBackLbl.Caption := WizardForm.BackButton.Caption;
  BtnNextLbl.Caption := WizardForm.NextButton.Caption;
  BtnCancelLbl.Caption := WizardForm.CancelButton.Caption;

  BtnBackImg.Visible := WizardForm.BackButton.Visible and WizardForm.BackButton.Enabled;
  BtnBackLbl.Visible := BtnBackImg.Visible;
  BtnNextImg.Visible := WizardForm.NextButton.Visible;
  BtnNextLbl.Visible := BtnNextImg.Visible;
  BtnCancelImg.Visible := WizardForm.CancelButton.Visible;
  BtnCancelLbl.Visible := BtnCancelImg.Visible;

  if WizardForm.NextButton.Enabled then
    BtnNextLbl.Font.Color := clTxt
  else
    BtnNextLbl.Font.Color := clFaint;

  if WizardForm.CancelButton.Enabled then
    BtnCancelLbl.Font.Color := clBody
  else
    BtnCancelLbl.Font.Color := clFaint;
end;

procedure ApplyPrismTheme;
begin
  WizardForm.Color := clBg;
  WizardForm.Font.Name := 'Segoe UI';

  { Шапка со значком и подписью страницы. }
  try
    WizardForm.MainPanel.Color := clHeader;
    WizardForm.Bevel.Visible := False;
    WizardForm.Bevel1.Visible := False;
  except
  end;
  PaintText(WizardForm.PageNameLabel, clTxt, 10, True);
  PaintText(WizardForm.PageDescriptionLabel, clSub, 8, False);


  { Приветствие и завершение. }
  PaintText(WizardForm.WelcomeLabel1, clTxt, 16, True);
  PaintText(WizardForm.WelcomeLabel2, clBody, 9, False);
  PaintText(WizardForm.FinishedHeadingLabel, clTxt, 16, True);
  PaintText(WizardForm.FinishedLabel, clBody, 9, False);

  { Выбор папки. }
  PaintText(WizardForm.SelectDirLabel, clBody, 9, False);
  PaintText(WizardForm.SelectDirBrowseLabel, clSub, 9, False);
  PaintText(WizardForm.DiskSpaceLabel, clFaint, 8, False);
  try
    WizardForm.DirEdit.Color := clField;
    WizardForm.DirEdit.Font.Color := clTxt;
  except
  end;

  { Задачи и сводка. }
  PaintText(WizardForm.SelectTasksLabel, clBody, 9, False);
  try
    WizardForm.TasksList.Color := clBg;
    WizardForm.TasksList.Font.Color := clBody;
  except
  end;
  PaintText(WizardForm.ReadyLabel, clBody, 9, False);
  try
    WizardForm.ReadyMemo.Color := clSolid;
    WizardForm.ReadyMemo.Font.Color := clBody;
  except
  end;

  { Установка. }
  PaintText(WizardForm.StatusLabel, clBody, 9, False);
  PaintText(WizardForm.FilenameLabel, clFaint, 8, False);
  PaintText(WizardForm.PreparingLabel, clBody, 9, False);

  { Список «что сделать после установки» на последней странице. Без него
    флажок «Запустить Nexus Nimbus» остаётся тёмным на тёмном. }
  try
    WizardForm.RunList.Color := clBg;
    WizardForm.RunList.Font.Color := clBody;
  except
  end;

  { Страницы, которые сейчас выключены, но включатся, если однажды
    понадобятся: лицензия, выбор компонентов, папка меню «Пуск». Красим
    заранее — иначе включение любой из них вернёт белое пятно. }
  PaintText(WizardForm.SelectComponentsLabel, clBody, 9, False);
  PaintText(WizardForm.ComponentsDiskSpaceLabel, clFaint, 8, False);
  try
    WizardForm.ComponentsList.Color := clBg;
    WizardForm.ComponentsList.Font.Color := clBody;
    WizardForm.TypesCombo.Color := clField;
    WizardForm.TypesCombo.Font.Color := clTxt;
  except
  end;

  PaintText(WizardForm.SelectStartMenuFolderLabel, clBody, 9, False);
  PaintText(WizardForm.SelectStartMenuFolderBrowseLabel, clSub, 9, False);
  try
    WizardForm.GroupEdit.Color := clField;
    WizardForm.GroupEdit.Font.Color := clTxt;
    WizardForm.NoIconsCheck.Font.Color := clBody;
  except
  end;

  PaintText(WizardForm.LicenseLabel1, clBody, 9, False);
  try
    WizardForm.LicenseMemo.Color := clSolid;
    WizardForm.LicenseMemo.Font.Color := clBody;
    WizardForm.LicenseAcceptedRadio.Font.Color := clBody;
    WizardForm.LicenseNotAcceptedRadio.Font.Color := clBody;
  except
  end;

  try
    WizardForm.InfoBeforeMemo.Color := clSolid;
    WizardForm.InfoBeforeMemo.Font.Color := clBody;
    WizardForm.InfoAfterMemo.Color := clSolid;
    WizardForm.InfoAfterMemo.Font.Color := clBody;
    WizardForm.YesRadio.Font.Color := clBody;
    WizardForm.NoRadio.Font.Color := clBody;
  except
  end;

  PaintText(WizardForm.BeveledLabel, clFaint, 8, False);

  { Фон страниц красится ПОСЛЕДНИМ. Смена Color пересоздаёт окно страницы
    вместе с дочерними элементами, и всё, что настроено до этого, теряется —
    порядок здесь не вкусовщина. }
  PaintPage(WizardForm.WelcomePage);
  PaintPage(WizardForm.InnerPage);
  PaintPage(WizardForm.LicensePage);
  PaintPage(WizardForm.PasswordPage);
  PaintPage(WizardForm.InfoBeforePage);
  PaintPage(WizardForm.UserInfoPage);
  PaintPage(WizardForm.SelectDirPage);
  PaintPage(WizardForm.SelectComponentsPage);
  PaintPage(WizardForm.SelectProgramGroupPage);
  PaintPage(WizardForm.SelectTasksPage);
  PaintPage(WizardForm.ReadyPage);
  PaintPage(WizardForm.PreparingPage);
  PaintPage(WizardForm.InstallingPage);
  PaintPage(WizardForm.InfoAfterPage);
  PaintPage(WizardForm.FinishedPage);
end;

procedure BuildProgressBar;
begin
  { Стандартная полоса подчиняется теме Windows, поэтому вместо неё — две
    панели: дорожка и акцентная заливка, ширину которой мы двигаем сами. }
  WizardForm.ProgressGauge.Visible := False;

  ProgressTrack := TPanel.Create(WizardForm);
  ProgressTrack.Parent := WizardForm.ProgressGauge.Parent;
  ProgressTrack.SetBounds(
    WizardForm.ProgressGauge.Left,
    WizardForm.ProgressGauge.Top + 4,
    WizardForm.ProgressGauge.Width,
    8);
  ProgressTrack.BevelOuter := bvNone;
  ProgressTrack.Color := clChip;

  ProgressFill := TPanel.Create(WizardForm);
  ProgressFill.Parent := ProgressTrack;
  ProgressFill.SetBounds(0, 0, 0, ProgressTrack.Height);
  ProgressFill.BevelOuter := bvNone;
  ProgressFill.Color := clAccent;
end;

procedure InitializeWizard;
begin
  ApplyPrismTheme;
  BuildProgressBar;
  MakeButton(WizardForm.BackButton, False, BtnBackImg, BtnBackLbl, @OnBackClick);
  MakeButton(WizardForm.NextButton, True, BtnNextImg, BtnNextLbl, @OnNextClick);
  MakeButton(WizardForm.CancelButton, False, BtnCancelImg, BtnCancelLbl, @OnCancelClick);
  SyncButtons;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  SyncButtons;
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  if (ProgressFill <> nil) and (MaxProgress > 0) then
    ProgressFill.Width := (ProgressTrack.Width * CurProgress) div MaxProgress;
  SyncButtons;
end;
