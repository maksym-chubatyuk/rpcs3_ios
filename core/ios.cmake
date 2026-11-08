# The iOS layer over RPCS3's own CMake build. scripts/build-core.sh passes this file as
# CMAKE_PROJECT_rpcs3_INCLUDE, so CMake runs it right after RPCS3's project() call: it sets up
# the iOS build without editing RPCS3's CMakeLists.txt, and adds our targets (targets.cmake) once
# RPCS3's have been defined.

set(RPCS3_IOS ON)
set(RPCS3_IOS_CORE "${CMAKE_CURRENT_LIST_DIR}")
message(STATUS "RPCS3: building the emulator core for iOS (${RPCS3_IOS_CORE})")

add_compile_definitions(RPCS3_IOS=1)
include_directories(BEFORE "${RPCS3_IOS_CORE}/include")
add_compile_options("SHELL:-include ${RPCS3_IOS_CORE}/include/ios/compat.h")

# Nothing comes from the system. SDL3, FFmpeg and MoltenVK are built for iOS by our scripts and
# found through CMAKE_FIND_ROOT_PATH; the rest is RPCS3's bundled copy.
set(USE_SYSTEM_SDL ON CACHE BOOL "iOS: SDL3 from scripts/build-sdl-ios.sh" FORCE)
set(USE_SYSTEM_FFMPEG ON CACHE BOOL "iOS: FFmpeg from scripts/build-ffmpeg-ios.sh" FORCE)
set(USE_SYSTEM_MVK ON CACHE BOOL "iOS: MoltenVK, linked statically" FORCE)
foreach(option USE_SYSTEM_ZLIB USE_SYSTEM_CURL USE_SYSTEM_OPENAL USE_LIBEVDEV USE_DISCORD_RPC
               USE_GAMEMODE USE_NATIVE_INSTRUCTIONS USE_PRECOMPILED_HEADERS)
    set(${option} OFF CACHE BOOL "Off on iOS" FORCE)
endforeach()
# cubeb's AudioUnit backend is macOS-only; iOS audio goes through FAudio (SDL3)
set(USE_AUDIOUNIT OFF CACHE BOOL "Off on iOS" FORCE)

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL include "${RPCS3_IOS_CORE}/targets.cmake")
