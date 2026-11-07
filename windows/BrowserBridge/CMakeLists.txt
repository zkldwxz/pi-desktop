cmake_minimum_required(VERSION 3.14)
project(browser_bridge LANGUAGES CXX)

# pi-desktop-browser-host.exe, the browsers' native messaging host (host.cpp).
# It goes beside baocode.exe with dev.pi.desktop.browser.json, the manifest
# the browsers find it by: the installer's keys point there (see
# tool/baocode.iss), and its "path", relative, is the host beside it.
add_executable(pi-desktop-browser-host "host.cpp")
apply_standard_settings(pi-desktop-browser-host)
target_compile_options(pi-desktop-browser-host PRIVATE /utf-8)
target_compile_definitions(pi-desktop-browser-host PRIVATE
  "NOMINMAX" "WIN32_LEAN_AND_MEAN")
target_link_libraries(pi-desktop-browser-host PRIVATE "ws2_32.lib")
