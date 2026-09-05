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
static void FocusExistingWindow() {
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", kWindowTitle);
  if (!existing) {
    return;
  }
  if (::IsIconic(existing)) {
    ::ShowWindow(existing, SW_RESTORE);
  }
  ::SetForegroundWindow(existing);
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Мьютекс держится до конца процесса; освобождать вручную не нужно —
  // Windows закроет описатель при выходе, в том числе при падении.
  HANDLE single_instance = ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    FocusExistingWindow();
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
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
