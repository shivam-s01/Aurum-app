cmake_minimum_required(VERSION 3.22.1)
project("aurumguard")

# Aggressive size/strip settings so the resulting .so carries minimal
# symbol information — this is part of what makes native disassembly
# harder than reading obfuscated Kotlin: fewer names, no debug info.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=hidden -fvisibility-inlines-hidden -ffunction-sections -fdata-sections")
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,--gc-sections -Wl,--strip-all")

add_library(aurumguard SHARED
        aurum_guard.cpp)

find_library(log-lib log)

target_link_libraries(aurumguard
        ${log-lib})
