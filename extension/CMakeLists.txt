cmake_minimum_required(VERSION 3.17)
project(motionbricks_gd LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# godot-cpp 4.5 is cloned by scripts/build-extension-mac.sh; pass its location as GODOTCPP_DIR.
if(NOT GODOTCPP_DIR)
  set(GODOTCPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp")
endif()
add_subdirectory("${GODOTCPP_DIR}" godot-cpp)

# Where the finished extension library goes (the Godot project's bin/ folder).
if(NOT MB_GD_OUTPUT_DIR)
  set(MB_GD_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/bin")
endif()

add_library(motionbricks_gd SHARED
  src/register_types.cpp
  src/motionbricks_probe.cpp
  src/motionbricks_g1.cpp
)
# Headers of motion-bricks.cpp (types and signatures only; the library itself is loaded at runtime).
if(NOT MB_INCLUDE_DIR)
  set(MB_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/motion-bricks.cpp/include")
endif()
target_include_directories(motionbricks_gd PRIVATE "${MB_INCLUDE_DIR}")
target_link_libraries(motionbricks_gd PRIVATE godot-cpp)

set_target_properties(motionbricks_gd PROPERTIES
  PREFIX "lib"
  OUTPUT_NAME "motionbricks_gd"
  LIBRARY_OUTPUT_DIRECTORY "${MB_GD_OUTPUT_DIR}"
  POSITION_INDEPENDENT_CODE ON
)
if(APPLE)
  set_target_properties(motionbricks_gd PROPERTIES SUFFIX ".dylib")
endif()
