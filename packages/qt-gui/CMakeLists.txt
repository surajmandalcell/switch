cmake_minimum_required(VERSION 3.21)
project(Switch LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Screenshot and input harness (private Qt headers). Shipping builds turn it off.
option(SWITCH_HARNESS "Build the screenshot and input harness" ON)
option(SWITCH_TESTS "Build the helper client test" ON)

# License rules (README "Licensing"): LGPL Qt modules only, linked dynamically; qmlsc (GPL-only) never runs.
# Without this, Qt6Qml looks for the qmlsc package and qt_add_qml_module prefers it over qmlcachegen.
set(QT_NO_FIND_QMLSC TRUE)
set(BUILD_SHARED_LIBS ON)

set(SWITCH_QT_MODULES Core Gui Qml Quick Widgets)
if(SWITCH_HARNESS)
  list(APPEND SWITCH_QT_MODULES GuiPrivate)
endif()
if(SWITCH_TESTS)
  list(APPEND SWITCH_QT_MODULES Test)
endif()
find_package(Qt6 6.8 REQUIRED COMPONENTS ${SWITCH_QT_MODULES})
qt_policy(SET QTP0001 NEW)
qt_policy(SET QTP0004 OLD)

if(TARGET Qt6::qmlsc)
  message(FATAL_ERROR "qmlsc (GPL-only QML script compiler) is visible to this build. It must never run: "
                      "remove QT_NO_FIND_QMLSC overrides or the Qt6QmlCompilerPlusPrivateTools package from the prefix.")
endif()
get_target_property(_qt_core_type Qt6::Core TYPE)
if(NOT _qt_core_type STREQUAL "SHARED_LIBRARY")
  message(FATAL_ERROR "Qt must be linked dynamically (LGPL); Qt6::Core is ${_qt_core_type}.")
endif()

# Source folders for people, one flat module folder at run time (the Theme singleton must not be
# shadowed by a directory import, and every QML file sees every other one without imports).
file(GLOB_RECURSE QML_SRC RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS qml/*.qml qml/*.js)
foreach(f ${QML_SRC})
  get_filename_component(n ${f} NAME)
  set_source_files_properties(${f} PROPERTIES QT_RESOURCE_ALIAS ${n})
endforeach()
set_source_files_properties(qml/components/Theme.qml qml/components/Prefs.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
# Provider marks copied from the Mac resources (assets/providers/brand/BRAND-SOURCES.md has sources and licenses).
file(GLOB_RECURSE PROVIDER_ASSETS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS assets/providers/*.png assets/providers/*.svg)

qt_add_executable(switch
  src/main.cpp
  src/appstate.cpp src/appstate.h
  src/helperclient.cpp src/helperclient.h
  src/tray.cpp src/tray.h
  src/globalshortcut.cpp src/globalshortcut.h
  src/notifier.cpp src/notifier.h
)
if(SWITCH_HARNESS)
  target_sources(switch PRIVATE src/harness.cpp src/harness.h)
  target_compile_definitions(switch PRIVATE SWITCH_HARNESS)
endif()
# Windows: a shipping build is a GUI program (no console window); harness builds keep the console for their logs.
# The property does nothing on other platforms.
if(NOT SWITCH_HARNESS)
  set_target_properties(switch PROPERTIES WIN32_EXECUTABLE ON)
endif()

# qmlcachegen stops the whole build at the first QML syntax error and has no keep-going flag. When a build
# fails, scripts/build.sh builds again with this OFF, so a broken file fails only its own page at run time.
option(SWITCH_CACHEGEN "Compile QML ahead of time with qmlcachegen" ON)
set(SWITCH_QML_CACHEGEN)
if(NOT SWITCH_CACHEGEN)
  set(SWITCH_QML_CACHEGEN NO_CACHEGEN)
endif()

qt_add_qml_module(switch
  URI SwitchUI
  VERSION 1.0
  ${SWITCH_QML_CACHEGEN}
  QML_FILES ${QML_SRC}
  RESOURCES
    fonts/InterVariable.ttf
    fonts/JetBrainsMono-Regular.ttf
    assets/tray.png
    assets/tray@2x.png
    assets/appicon.png
    assets/demo.json
    ${PROVIDER_ASSETS}
)
# Pin the cache compiler: qmlcachegen (Qt tools), never qmlsc.
set_target_properties(switch PROPERTIES QT_QMLCACHEGEN_EXECUTABLE qmlcachegen)

target_link_libraries(switch PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::Widgets)
if(SWITCH_HARNESS)
  target_link_libraries(switch PRIVATE Qt6::GuiPrivate)
endif()
# Linux only: Qt D-Bus (LGPL, Qt base) for the XDG GlobalShortcuts portal and desktop notifications.
if(UNIX AND NOT APPLE)
  find_package(Qt6 6.8 REQUIRED COMPONENTS DBus)
  target_link_libraries(switch PRIVATE Qt6::DBus)
  target_compile_definitions(switch PRIVATE SWITCH_DBUS)
  # libxcb (MIT; Qt's xcb platform plugin already needs it) for the X11 shortcut grab when no portal exists.
  # Without its headers the app builds with the portal only.
  find_path(XCB_INCLUDE_DIR xcb/xcb.h)
  find_library(XCB_LIBRARY xcb)
  if(XCB_INCLUDE_DIR AND XCB_LIBRARY)
    target_include_directories(switch PRIVATE ${XCB_INCLUDE_DIR})
    target_link_libraries(switch PRIVATE ${XCB_LIBRARY})
    target_compile_definitions(switch PRIVATE SWITCH_XCB)
  else()
    message(WARNING "libxcb headers not found: the menu shortcut has no X11 fallback (install libxcb1-dev or libxcb-devel)")
  endif()
endif()

if(SWITCH_TESTS)
  qt_add_executable(tst_helperclient tests/tst_helperclient.cpp src/helperclient.cpp src/helperclient.h)
  target_include_directories(tst_helperclient PRIVATE src)
  target_link_libraries(tst_helperclient PRIVATE Qt6::Core Qt6::Qml Qt6::Test)
  enable_testing()
  add_test(NAME helperclient COMMAND tst_helperclient)
  qt_add_executable(tst_globalshortcut tests/tst_globalshortcut.cpp src/globalshortcut.cpp src/globalshortcut.h)
  target_include_directories(tst_globalshortcut PRIVATE src)
  target_link_libraries(tst_globalshortcut PRIVATE Qt6::Core Qt6::Test)
  if(UNIX AND NOT APPLE)
    target_link_libraries(tst_globalshortcut PRIVATE Qt6::DBus)
    target_compile_definitions(tst_globalshortcut PRIVATE SWITCH_DBUS)
  endif()
  add_test(NAME globalshortcut COMMAND tst_globalshortcut)
endif()

# Fail the configure step if a GPL-only or excluded Qt module reaches a link line.
foreach(t switch tst_helperclient tst_globalshortcut)
  if(TARGET ${t})
    get_target_property(_libs ${t} LINK_LIBRARIES)
    foreach(l ${_libs})
      if(l MATCHES "Qt6::(Graphs|Charts|Quick3D|ShaderTools|QuickTimeline|DataVisualization|VirtualKeyboard)")
        message(FATAL_ERROR "${t} links ${l}, which is GPL-only or excluded (README Licensing).")
      endif()
    endforeach()
  endif()
endforeach()
