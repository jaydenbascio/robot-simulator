add_library(project_warnings INTERFACE)

if(MSVC)
    target_compile_options(project_warnings INTERFACE
        /W4           # High warning level
        /WX           # Treat warnings as errors
        /permissive-  # Enforce standard conformance
        /wd4100       # Must use (void)param to explicitly declare unused parameters
        /EHsc         # Enable standard C++ exception handling
    )
else()
    target_compile_options(project_warnings INTERFACE
        -Wall
        -Wextra
        -Wpedantic
        -Wshadow
        -Wunused
        -Werror                # Treat warnings as errors
        -Wno-unused-parameter  # Must use (void)param to explicitly declare unused parameters
    )
endif()

install(TARGETS project_warnings
    EXPORT RobotSimulatorTargets
)
