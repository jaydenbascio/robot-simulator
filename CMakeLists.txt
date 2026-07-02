cmake_minimum_required(VERSION 3.20)
project(RobotSimulator VERSION 1.0.0 LANGUAGES CXX)

# Global C++ Standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)  # Require strict ISO C++

# Add custom CMake configuration files under /cmake
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(CompilerOptions)
include(ProjectVersion)

# For distribution and installation
include(GNUInstallDirs)

# Testing configuration (must be called before adding subdirectories that contain tests)
include(CTest)

# Custom libraries
add_subdirectory(libs/ui)
add_subdirectory(libs/engine)

# Applications
add_subdirectory(apps)

