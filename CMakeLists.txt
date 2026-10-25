cmake_minimum_required(VERSION 3.24)

project(SimplePlayer
    VERSION 0.1.0
    DESCRIPTION "A native macOS video player built with Qt + libmpv"
    LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# --- Qt ---
find_package(Qt6 6.5 REQUIRED COMPONENTS Quick)
qt_standard_project_setup()

# macOS 27 SDK 移除了 AGL framework，Homebrew Qt 的 WrapOpenGL 仍会无条件
# 注入 "-framework AGL"，导致链接失败；这里改回仅链接 OpenGL framework。
if(APPLE AND TARGET WrapOpenGL::WrapOpenGL)
    set_target_properties(WrapOpenGL::WrapOpenGL PROPERTIES
        INTERFACE_LINK_LIBRARIES "-framework OpenGL")
endif()

# --- libmpv ---
# 开发阶段直接链接 Homebrew 的 libmpv；发布打包（M4）时切换为 MPVKit 静态库
find_library(MPV_LIBRARY
    NAMES mpv
    HINTS /opt/homebrew/lib /usr/local/lib)
find_path(MPV_INCLUDE_DIR
    NAMES mpv/client.h
    HINTS /opt/homebrew/include /usr/local/include)
if(NOT MPV_LIBRARY OR NOT MPV_INCLUDE_DIR)
    message(FATAL_ERROR "libmpv not found. Run: brew install mpv")
endif()

# 应用图标（macOS）
set(APP_ICON_MACOSX ${CMAKE_CURRENT_SOURCE_DIR}/assets/SimplePlayer.icns)
set_source_files_properties(${APP_ICON_MACOSX} PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources")

qt_add_executable(SimplePlayer MACOSX_BUNDLE
    src/main.cpp
    src/mpv/MpvObject.h
    src/mpv/MpvObject.cpp
    resources.qrc
    ${APP_ICON_MACOSX}
)

target_include_directories(SimplePlayer PRIVATE
    src
    ${MPV_INCLUDE_DIR}
)

target_link_libraries(SimplePlayer PRIVATE
    Qt6::Quick
    ${MPV_LIBRARY}
)

set_target_properties(SimplePlayer PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.simpleplayer.dev"
    MACOSX_BUNDLE_BUNDLE_NAME "SimplePlayer"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
    MACOSX_BUNDLE_BUNDLE_VERSION 1
    MACOSX_BUNDLE_ICON_FILE SimplePlayer
)
