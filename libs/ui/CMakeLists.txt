find_package(SDL3 REQUIRED)

add_library(robotsimulator_ui STATIC)
add_library(robotsimulator::ui ALIAS robotsimulator_ui)

target_sources(robotsimulator_ui
    PRIVATE
        "src/Renderer2D.cpp"
)

target_include_directories(robotsimulator_ui
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(robotsimulator_ui
    PRIVATE
        SDL3::SDL3
        project_warnings
)

# No unit testing for ui and graphics; SDL3 makes it very difficult
#
# if(BUILD_TESTING)
#     add_subdirectory(tests)
# endif()

# --- Installation ---
install(TARGETS robotsimulator_ui
    EXPORT RobotSimulatorTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(DIRECTORY include/ui
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
