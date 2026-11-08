# The emulator core as a dynamic framework (RPCS3Core.framework) for the app, from targets.cmake.
#
# The app loads it with dlopen() only after it holds a JIT pool, because static initializers in
# the core already generate code (see include/ios/jit_pool.hpp). It links nothing from it directly.

set(RPCS3_SRC ${CMAKE_SOURCE_DIR}/rpcs3)

add_library(rpcs3_ios_input STATIC
    ${RPCS3_SRC}/Input/blob_detector.cpp
    ${RPCS3_SRC}/Input/mouse_gyro_handler.cpp
    ${RPCS3_SRC}/Input/wiimote_handler.cpp
    ${RPCS3_SRC}/Input/ds3_pad_handler.cpp
    ${RPCS3_SRC}/Input/ds4_pad_handler.cpp
    ${RPCS3_SRC}/Input/dualsense_pad_handler.cpp
    ${RPCS3_SRC}/Input/hid_instance.cpp
    ${RPCS3_SRC}/Input/hid_pad_handler.cpp
    ${RPCS3_SRC}/Input/pad_thread.cpp
    ${RPCS3_SRC}/Input/product_info.cpp
    ${RPCS3_SRC}/Input/ps_move_calibration.cpp
    ${RPCS3_SRC}/Input/ps_move_config.cpp
    ${RPCS3_SRC}/Input/ps_move_handler.cpp
    ${RPCS3_SRC}/Input/ps_move_tracker.cpp
    ${RPCS3_SRC}/Input/raw_mouse_config.cpp
    ${RPCS3_SRC}/Input/sdl_instance.cpp
    ${RPCS3_SRC}/Input/sdl_pad_handler.cpp
    ${RPCS3_SRC}/Input/skateboard_pad_handler.cpp
)
target_link_libraries(rpcs3_ios_input PUBLIC rpcs3_emu 3rdparty::hidapi 3rdparty::sdl3)

add_library(RPCS3Core SHARED
    ${RPCS3_IOS_CORE}/rpcs3_ios.mm
    ${RPCS3_IOS_CORE}/rpcs3_ios.h
    ${RPCS3_IOS_CORE}/settings.cpp
    ${RPCS3_IOS_CORE}/config_json.cpp
    ${RPCS3_IOS_CORE}/games.cpp
    ${RPCS3_IOS_CORE}/patches.cpp
    ${RPCS3_IOS_CORE}/controls.cpp
    ${RPCS3_IOS_CORE}/userdata.cpp
    ${RPCS3_SRC}/rpcs3_version.cpp
    ${RPCS3_SRC}/stdafx.cpp
)

set_source_files_properties(${RPCS3_IOS_CORE}/rpcs3_ios.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")

target_link_libraries(RPCS3Core
    PRIVATE
        rpcs3_ios_input
        rpcs3_emu
        3rdparty::stblib
        3rdparty::yaml-cpp
        3rdparty::hidapi
        3rdparty::libusb
        3rdparty::wolfssl
        3rdparty::libcurl
        3rdparty::zlib
        3rdparty::fusion
        "-framework Foundation"
        "-framework UIKit"
        "-framework QuartzCore"
        "-framework Metal"
        "-framework IOSurface"
        "-framework CoreAudio"
        "-framework AudioToolbox"
        "-framework AVFoundation"
        "-framework GameController"
        "-framework CoreHaptics"
        "-framework CoreMotion"
        "-framework CoreBluetooth"
        "-framework Security"
        "-framework SystemConfiguration"
        "-framework VideoToolbox"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework CoreFoundation"
        "-framework CoreGraphics"
        iconv
)

set_target_properties(RPCS3Core PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_IDENTIFIER "net.rpcs3.ios.core"
    MACOSX_FRAMEWORK_BUNDLE_VERSION "1"
    MACOSX_FRAMEWORK_SHORT_VERSION_STRING "1.0"
    PUBLIC_HEADER ${RPCS3_IOS_CORE}/rpcs3_ios.h
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/ios
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON
)
