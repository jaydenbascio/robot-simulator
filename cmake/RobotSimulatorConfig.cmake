include(CMakeFindDependencyMacro)

# SDL3 required for the graphics side of this application
find_dependency(SDL3 CONFIG REQUIRED)

# Load the generated targets map
include("${CMAKE_CURRENT_LIST_DIR}/RobotSimulatorTargets.cmake")
