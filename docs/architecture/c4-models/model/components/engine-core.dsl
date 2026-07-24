engine = container "Simulation Engine Core" "Handles physics and robot state." "C++ Library" {
    
    # --- LEVEL 3: COMPONENTS ---
    physEngine = component "Jolt Physics Solver" "Updates virtual hardware state using the Jolt Physics engine" "Jolt Physics"
    v5HAL = component "V5 Hardware Abstraction Layer" "Provides a mock interface for PROS functionality" "C++"
    v5Hardware = component "V5 Hardware Emulators" "Maintains virtual hardware state and read/write buffers for user interface." "C++ / Jolt Physics"

    userProgram = component "Robot User Program" "Dynamically loads and runs user DLLs." "C++"
    orchestrator = component "Simulation Orchestrator" "Manages the simulation loop and provides an interface for external system control." "C++"

    # Layer 3 Internal Relationships
    orchestrator -> v5Hardware "Alters external input values (like controller) through"
    v5Hardware -> orchestrator "Sends external output values (like motor or sensor) through"
    orchestrator -> physEngine "Periodically updates virtual hardware state using"
    orchestrator -> userProgram "Loads and executes in modes like autonomous and operator control from"

    userProgram -> v5HAL "Calls functions to read/write virtual hardware through"
    physEngine -> v5Hardware "Updates virtual hardware state in"
    v5HAL -> v5Hardware "Reads and writes virtual hardware state to"
}
