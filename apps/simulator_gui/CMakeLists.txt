find_package(SDL3 REQUIRED)

add_executable(simulator-gui)

target_sources(simulator-gui
    PRIVATE
        src/main.cpp
)

target_link_libraries(simulator-gui
    PRIVATE
        robotsimulator::engine
        robotsimulator::ui
        SDL3::SDL3
        project_warnings
        project::version
)

# -------------------------
# Installation & Packaging
# -------------------------
install(TARGETS simulator-gui
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
