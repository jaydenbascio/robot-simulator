rs = softwareSystem "Robot Simulator System" "Simulates robot physics, sensor data, and execution environments." {
    # Front end / interfaces containers
    gui = container "Desktop GUI App" "Provides real-time 2D visual feedback, field rendering, and manual control." "SDL3 C++ Application"
    cli = container "CLI Runner" "Headless interface for running automated unit tests for technologies like CI" "Command Line Executable"
    pid = container "Auto Tuning Runner" "Automation program that executes iterative simulations to tune control variables." "Command Line Executable"
    
    # Main subsystems
    build = container "Build Toolchain" "Compiles the user's Vex V5 source code into a dynamic library" "CMake / Clang / Ninja"
    !include components/engine-core.dsl
    
    # Relationships inside the system (Component-level targets)
    build -> engine.userProgram "Loads compiled robot DLLs to"
    
    # Point the front-ends directly to the component orchestrator that they drive
    gui -> engine.orchestrator "Drives execution and reads state from"
    cli -> engine.orchestrator "Executes test scripts against"
    pid -> engine.orchestrator "Runs iterative simulations using"
}
