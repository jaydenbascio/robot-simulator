find_package(Catch2 REQUIRED)

add_executable(robotsimulator_engine_tests)

target_sources(robotsimulator_engine_tests
    PRIVATE
        Simulator_test.cpp
)

target_link_libraries(robotsimulator_engine_tests
    PRIVATE
        robotsimulator::engine
        Catch2::Catch2WithMain
        project_warnings
)

include(Catch)
catch_discover_tests(robotsimulator_engine_tests
    DISCOVERY_MODE PRE_TEST
)
