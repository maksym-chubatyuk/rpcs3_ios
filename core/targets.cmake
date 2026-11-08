# Runs at the end of RPCS3's top-level CMakeLists.txt (deferred by ios.cmake), when its targets exist.

# The JIT pool and its LLVM memory manager, used by the patched JIT code (patches/0002, 0003)
target_sources(rpcs3_emu PRIVATE
    "${RPCS3_IOS_CORE}/jit_pool.cpp"
    "${RPCS3_IOS_CORE}/jit_llvm_memory.cpp"
)
# Like RPCS3's own LLVM code (JITLLVM.cpp): LLVM is built without RTTI
set_source_files_properties("${RPCS3_IOS_CORE}/jit_llvm_memory.cpp" TARGET_DIRECTORY rpcs3_emu PROPERTIES COMPILE_FLAGS -fno-rtti)

# libusb's null backend (patches/0007) needs a clock function from the platform code it replaces
target_sources(usb-1.0-static PRIVATE "${RPCS3_IOS_CORE}/libusb_ios_time.c")

# hidapi over libusb's null backend: iOS has no IOKit HID
set_property(TARGET 3rdparty_hidapi PROPERTY INTERFACE_LINK_LIBRARIES hidapi_libusb)

# The bridge to the app: RPCS3Core.framework (deferred code may not add subdirectories)
include("${RPCS3_IOS_CORE}/bridge.cmake")
