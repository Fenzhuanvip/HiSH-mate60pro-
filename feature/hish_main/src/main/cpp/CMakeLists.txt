# minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(hish)
set(PROJECT_LANGUAGE C)
if(DEFINED CMAKE_CXX_COMPILER)
  set(CMAKE_CXX_STANDARD 17)
  list(APPEND PROJECT_LANGUAGES CXX)
endif(DEFINED CMAKE_CXX_COMPILER)

project(HiSH VERSION 1.0.0 LANGUAGES ${PROJECT_LANGUAGES})

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Include directories
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

# HiSH sources
add_library(hish_main SHARED
    napi_init.cpp
)

target_link_libraries(hish_main PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libdl.so
)

# ArkPilot codex host bridge (Rust). Conditional: if the .so was built and
# placed under libs/<arch>/, link it; otherwise the NAPI layer gracefully
# reports a load error at runtime via dlopen.
set(RUST_BRIDGE_LIB_NAME libcodex_ohos_host.so)
set(RUST_BRIDGE_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH})
set(RUST_BRIDGE_LIB_PATH ${RUST_BRIDGE_LIB_DIR}/${RUST_BRIDGE_LIB_NAME})
if(EXISTS ${RUST_BRIDGE_LIB_PATH})
    target_link_directories(hish_main PUBLIC ${RUST_BRIDGE_LIB_DIR})
    target_link_libraries(hish_main PUBLIC ${RUST_BRIDGE_LIB_NAME})
endif()

target_compile_options(hish_main PRIVATE -O2 -flto)
target_link_options(hish_main PRIVATE -flto)
