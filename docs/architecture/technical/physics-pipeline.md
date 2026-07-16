# Physics Pipeline Specification

## 1. Overview and Architecture
This document specifies the physics subsystem used for this project, its interface with external components, and the pros and cons of the model we designed for it.

* **Core Engine:** Box2D
* **Concurrency:** Asynchronous execution on a seperate physics thread. 
* **State Management:** Double-buffered registry model to eliminate race conditions between the simulation and external subsystems.

## 2. Component Registries and Concurrency Model
The subsystem isolates state across three distinct registries. Data permissions and access patterns are very much enforced according to the table below:

### Registry Access Table

| Registry | Structures Used | Physics Thread | External Subsystems / User Program | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Internal** | Box2D Native | Read / Write | **No Access** | Internal simulation state and frame updates |
| **Read-Only** | Custom Structs | Write Only | **Read Only** | Telemetry collection (for Orchestrator and HAL) |
| **Write-Only** | Custom Structs | Read Only | **Write Only** | Robot actuation and user command inputs |

---

### How Our Model Works

1. **Input Phase:** The user program writes target states (e.g., motor velocities) to the **Write-Only Registry**.
2. **Simulation Phase:** The physics thread reads from the **Write-Only Registry**, updates the **Internal Registry** via Box2D, and simulates the frame.
3. **Output Phase:** The physics thread copies the new environment and sensor states into the **Read-Only Registry**, making it available for the Orchestrator and Hardware Abstraction Layer (HAL) to use.

---

## 3. Trade-offs and Considerations

### Pros
* **Thread Safety:** Lock-free reads/writes for external subsystems prevent the user program from dragging down the physics loop.
* **Decoupling:** The user program interacts entirely with abstract custom structures, isolating it from raw Box2D implementations.

### Cons
* **Frame Latency:** Double-buffered updates introduce a 1-frame delay between a command being written and its simulated physical manifestation.
* **Memory Overhead:** Maintaining three separate state representations increases the memory footprint.

### Justification
As long as your computer does not have the computational equivilance of a toaster, the 1-frame delay will barely be noticable. Also, the memory overhead is negligible at this scale.
