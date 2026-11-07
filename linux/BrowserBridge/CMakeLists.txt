cmake_minimum_required(VERSION 3.13)
project(browser_bridge LANGUAGES C)

# pi-desktop-browser-host, the browsers' native messaging host: macOS's
# (macos/BrowserBridge/host.c), built here too. It goes beside pi-desktop,
# where BrowserBridge.hostExecutable finds it, and the manifests BaoCode
# writes in each browser's folder name it there.
find_package(Threads REQUIRED)
add_executable(pi-desktop-browser-host
  "${CMAKE_CURRENT_SOURCE_DIR}/../../macos/BrowserBridge/host.c")
target_compile_options(pi-desktop-browser-host PRIVATE -Wall -Wextra -Werror)
target_compile_options(pi-desktop-browser-host PRIVATE
  "$<$<NOT:$<CONFIG:Debug>>:-O2>")
target_link_libraries(pi-desktop-browser-host PRIVATE Threads::Threads)
