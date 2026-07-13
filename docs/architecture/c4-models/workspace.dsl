workspace "Vex V5 Robot Simulator" "A virtual testing environment for robotics." {

    !identifiers hierarchical

    model {
        !include model/actors.dsl
        !include model/robot-simulator.dsl

        # Relationships between external systems
        u -> ide "Writes code in"
        ide -> rbt "Deploys code to"

        # Relationships between external systems and the robot simulator
        ide -> rs.build "Deploys code to"
        u -> rs "Configures and runs simulations in"
        u -> rs.gui "Interacts with the GUI to visualize and control the robot."
        u -> rs.cli "Runs automated tests in the CLI."
        u -> rs.pid "Runs auto-tuning simulations in the PID Tuner."
    }
    
    views {
        !include views/context.dsl
        !include views/container.dsl
        !include views/component.dsl
#       !include views/code.dsl
        !include views/styles.dsl
        
        theme default
    }
}