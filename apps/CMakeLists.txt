option(BUILD_APP_GUI  "Build simulator-gui (graphical interface)"  ON)

if(BUILD_APP_GUI)
    add_subdirectory(simulator_gui)
endif()
