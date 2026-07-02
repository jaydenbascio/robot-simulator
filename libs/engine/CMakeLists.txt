add_library(robotsimulator_engine STATIC)
add_library(robotsimulator::engine ALIAS robotsimulator_engine)

target_sources(robotsimulator_engine
    PRIVATE
        src/Simulator.cpp
)

target_include_directories(robotsimulator_engine
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(robotsimulator_engine
    PRIVATE
        project_warnings
        project::version
)

if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
