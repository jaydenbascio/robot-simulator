# Generate version header from ProjectVersion variables
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/version.h.in"
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/robotsimulator/version.h"
    @ONLY # Only replace variables that look like @VAR@
)

# Create an interface library to expose the version header to targets
add_library(project_version INTERFACE)
add_library(project::version ALIAS project_version)

target_include_directories(project_version INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/generated/include>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
)

install(TARGETS project_version
    EXPORT RobotSimulatorTargets
)

install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/generated/include/robotsimulator/version.h"
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/robotsimulator
)
