cmake_minimum_required(VERSION 3.24)

project(SimplePlayer
    VERSION 0.1.0
    DESCRIPTION "A native macOS video player built with Qt + libmpv"
    LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# --- Qt ---
find_package(Qt6 6.5 REQUIRED COMPONENTS Quick Network)
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
    src/AppController.h
    src/AppController.cpp
    src/platform/NativeMenuBar.h
    src/platform/NativeMenuBar.mm
    src/platform/MacWindowHelper.h
    src/platform/MacWindowHelper.mm
    src/stream/AceStream.h
    src/stream/AceStream.cpp
    src/stream/DockerClient.h
    src/stream/DockerClient.cpp
    src/mpv/MpvObject.h
    src/mpv/MpvObject.cpp
    src/update/UpdateChecker.h
    src/update/UpdateChecker.cpp
    resources.qrc
    ${APP_ICON_MACOSX}
)

target_include_directories(SimplePlayer PRIVATE
    src
    ${MPV_INCLUDE_DIR}
)

target_link_libraries(SimplePlayer PRIVATE
    Qt6::Quick
    Qt6::Network
    ${MPV_LIBRARY}
    "-framework Cocoa"
)

# 每次 build 前动态生成版本号头文件（git 短 hash + 时间戳）
# add_custom_target(ALL ...) 确保每次 make 都会跑，且在 add_dependencies 里
# 让 SimplePlayer 依赖它 → 头文件生成先于 main.cpp 编译
set(GENERATED_DIR ${CMAKE_BINARY_DIR}/generated)
set(BUILDINFO_HEADER ${GENERATED_DIR}/BuildInfo.h)
add_custom_target(GenBuildInfo ALL
    COMMAND ${CMAKE_COMMAND} -E make_directory ${GENERATED_DIR}
    COMMAND ${CMAKE_COMMAND}
        -DSRC_DIR=${CMAKE_CURRENT_SOURCE_DIR}
        -DOUT=${BUILDINFO_HEADER}
        -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/GenBuildInfo.cmake
    COMMENT "Generating BuildInfo.h (git hash + timestamp)"
)
add_dependencies(SimplePlayer GenBuildInfo)
target_include_directories(SimplePlayer PRIVATE ${GENERATED_DIR})

set_target_properties(SimplePlayer PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.simpleplayer.dev"
    MACOSX_BUNDLE_BUNDLE_NAME "SimplePlayer"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
    MACOSX_BUNDLE_BUNDLE_VERSION 1
    MACOSX_BUNDLE_ICON_FILE SimplePlayer
)

# --- 随包分发的 AceStream 引擎运行时（colima + lima + 虚拟机/容器镜像） ---
# 由 scripts/prepare-engine.sh 生成；缺失时跳过，App 会退化为使用系统上已有的容器服务
set(ENGINE_RUNTIME_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/acestream-engine)
if(EXISTS ${ENGINE_RUNTIME_DIR}/bin/colima)
    add_custom_command(TARGET SimplePlayer POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E rm -rf
                "$<TARGET_BUNDLE_CONTENT_DIR:SimplePlayer>/Resources/engine"
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${ENGINE_RUNTIME_DIR}
                "$<TARGET_BUNDLE_CONTENT_DIR:SimplePlayer>/Resources/engine"
        COMMENT "Copying bundled AceStream engine runtime")
else()
    message(STATUS "AceStream 引擎运行时未准备（可选）：scripts/prepare-engine.sh")
endif()

# 自更新脚本（放在 bundle/Contents/Resources 下供运行时调用）
add_custom_command(TARGET SimplePlayer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_BUNDLE_CONTENT_DIR:SimplePlayer>/Resources"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CMAKE_CURRENT_SOURCE_DIR}/scripts/post-update.sh
            "$<TARGET_BUNDLE_CONTENT_DIR:SimplePlayer>/Resources/post-update.sh"
    COMMAND chmod +x "$<TARGET_BUNDLE_CONTENT_DIR:SimplePlayer>/Resources/post-update.sh"
    COMMENT "Copying post-update.sh into bundle")
