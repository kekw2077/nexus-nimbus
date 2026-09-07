#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// Имя мьютекса единственной копии. Его же знает установщик (AppMutex в
// dist/installer.iss): по нему Setup видит запущенное приложение и закрывает
// его сам, вместо того чтобы упереться в занятые файлы посреди обновления.
// Менять имя можно только в двух местах разом.
constexpr const wchar_t kSingleInstanceMutex[] = L"NexusNimbus-SingleInstance-Mutex";

// Заголовок окна. Он же — то, что ищет вторая копия, чтобы отдать фокус
// первой; должен совпадать с title в WindowOptions на стороне Dart.
constexpr const wchar_t kWindowTitle[] = L"Nexus Nimbus";

// Поднимает уже запущенное окно и уходит. Без этого второй запуск ярлыка
// молча ничего бы не делал, и выглядело бы это как «программа не открывается».
// Возвращает true, если окно предыдущей копии нашлось и получило фокус.
static bool FocusExistingWindow() {
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", kWindowTitle);
  if (!existing) {
    return false;
  }
  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  }
  ::SetForegroundWindow(existing);
  return true;
}

// Занимает мьютекс единственной копии.
//
// Мьютекс сам по себе не значит, что копия жива: сразу после обновления
// установщик убивает старую копию и тут же запускает новую, а мьютекс в
// этот момент ещё не отпущен ядром. Раньше новая копия видела его, не
// находила окна и молча выходила — программа после обновления просто не
// поднималась. Поэтому уходим, только если окно действительно нашлось;
// иначе ждём, пока мьютекс освободится.
//
// Возвращает nullptr, если запущена живая копия и ей отдан фокус.
static HANDLE ClaimSingleInstance() {
  constexpr int kAttempts = 20;      // 20 × 250 мс = пять секунд
  constexpr DWORD kPauseMs = 250;

  for (int attempt = 0; attempt < kAttempts; ++attempt) {
    HANDLE mutex = ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
    if (mutex == nullptr) {
      return nullptr;
    }
    if (::GetLastError() != ERROR_ALREADY_EXISTS) {
      return mutex;
    }
    ::CloseHandle(mutex);

    // Копия с окном — значит, программа действительно запущена.
    if (FocusExistingWindow()) {
      return nullptr;
    }
    ::Sleep(kPauseMs);
  }

  // Мьютекс занят, а окна за пять секунд так и не появилось. Уступать
  // нечему: запускаемся, иначе после неудачного обновления программа
  // не откроется вовсе.
  return ::CreateMutexW(nullptr, FALSE, nullptr);
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Мьютекс держится до конца процесса; освобождать вручную не нужно —
  // Windows закроет описатель при выходе, в том числе при падении.
  HANDLE single_instance = ClaimSingleInstance();
  if (single_instance == nullptr) {
    return EXIT_SUCCESS;  // окно уже открыто, ему и отдали фокус
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
