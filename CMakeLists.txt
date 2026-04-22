cmake_minimum_required(VERSION 3.16)
project(groundnet VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(LUA_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lua-5.4.6)
set(LUA_SRC_DIR ${LUA_ROOT}/src)
set(LUA_CORE
  ${LUA_SRC_DIR}/lapi.c ${LUA_SRC_DIR}/lcode.c ${LUA_SRC_DIR}/lctype.c ${LUA_SRC_DIR}/ldebug.c
  ${LUA_SRC_DIR}/ldo.c ${LUA_SRC_DIR}/ldump.c ${LUA_SRC_DIR}/lfunc.c ${LUA_SRC_DIR}/lgc.c
  ${LUA_SRC_DIR}/llex.c ${LUA_SRC_DIR}/lmem.c ${LUA_SRC_DIR}/lobject.c ${LUA_SRC_DIR}/lopcodes.c
  ${LUA_SRC_DIR}/lparser.c ${LUA_SRC_DIR}/lstate.c ${LUA_SRC_DIR}/lstring.c ${LUA_SRC_DIR}/ltable.c
  ${LUA_SRC_DIR}/ltm.c ${LUA_SRC_DIR}/lundump.c ${LUA_SRC_DIR}/lvm.c ${LUA_SRC_DIR}/lzio.c
  ${LUA_SRC_DIR}/lauxlib.c ${LUA_SRC_DIR}/lbaselib.c ${LUA_SRC_DIR}/lcorolib.c ${LUA_SRC_DIR}/ldblib.c
  ${LUA_SRC_DIR}/liolib.c ${LUA_SRC_DIR}/lmathlib.c ${LUA_SRC_DIR}/loadlib.c ${LUA_SRC_DIR}/loslib.c
  ${LUA_SRC_DIR}/lstrlib.c ${LUA_SRC_DIR}/ltablib.c ${LUA_SRC_DIR}/lutf8lib.c ${LUA_SRC_DIR}/linit.c
)

add_library(lua54 STATIC ${LUA_CORE})
target_include_directories(lua54 PUBLIC ${LUA_SRC_DIR})

if(MSVC)
  target_compile_definitions(lua54 PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

add_executable(groundnet
  src/main.cpp
  src/core/skynet.cpp
  src/core/proto_packet.cpp
  src/core/actor_system.cpp
  src/net/http_ws_server.cpp
  src/net/sha1.c
)

add_executable(groundnet_roomd
  src/room_process_main.cpp
)
target_include_directories(groundnet_roomd PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
  ${LUA_SRC_DIR}
)
target_link_libraries(groundnet_roomd PRIVATE lua54 Threads::Threads)
if(WIN32)
  target_link_libraries(groundnet_roomd PRIVATE ws2_32)
endif()

target_include_directories(groundnet PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/include
  ${LUA_SRC_DIR}
)

find_package(Threads REQUIRED)
target_link_libraries(groundnet PRIVATE lua54 Threads::Threads)

if(WIN32)
  target_link_libraries(groundnet PRIVATE ws2_32 winhttp)
endif()

file(COPY ${CMAKE_CURRENT_SOURCE_DIR}/lua DESTINATION ${CMAKE_BINARY_DIR})
file(COPY ${CMAKE_CURRENT_SOURCE_DIR}/web DESTINATION ${CMAKE_BINARY_DIR})

# `file(COPY ...)` only runs at configure time; sync again on every link so
# editing lua/ or web/ without re-running cmake still updates the running server.
add_custom_command(
  TARGET groundnet POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${CMAKE_CURRENT_SOURCE_DIR}/lua ${CMAKE_BINARY_DIR}/lua
  COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${CMAKE_CURRENT_SOURCE_DIR}/web ${CMAKE_BINARY_DIR}/web
  COMMENT "Sync lua/ and web/ into build tree"
)
