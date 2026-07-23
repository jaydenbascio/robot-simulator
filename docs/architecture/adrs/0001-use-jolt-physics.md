# Use Jolt Physics for a 3D robot simulation

## Context and Problem Statement

We are developing a custom C++ simulator for VEX V5 robotics to test autonomous routines and other mechanics. We must select a core physics engine to use, in the process determining whether our simulation environment operates in 2D or 3D space.

The selected engine must be deterministic to support automated C++ unit testing via Catch2, so that simulated routines produce identical results across CI runs. Additionally, the engine should balance computational efficiency with accurate physics, and its API must easily integrate with our multithreaded architecture to ensure the physics stepping does not block the user code thread.

## Considered Options

### For a 2D engine:
* [Box2D](https://github.com/erincatto/box2d) – The standard engine for two dimensional physics in C++
* Custom Physics Engine - Write everything from scratch

### For a 3D engine:
* [Box3D](https://github.com/erincatto/box3d) - An open source physics engine designed by the same mastermind behind Box2D
* [NVIDIA PhysX](https://github.com/NVIDIA-Omniverse/PhysX) – NVIDIA's open source physics engine
* [Jolt Physics](https://github.com/jrouwe/joltphysics)

## Decision Outcome

Chosen option: "Jolt Physics", because of its speed, determinism, and robust multithreading capabilities. We discarded Box2D due to its low fidelity and lack of object oriented constructs (in later versions), which would play poorly in our application. We discarded Box3D because of its limited documentation, alpha status, and C based codebase.

* Jolt, being 3 dimensional, allows for more detailed simulation, such as vertical positioning of sensors or complex lifting mechanisms
* Jolt Physics is completely CPU based, meaning it's highly deterministic, which matches our goals
* Jolt utilizes multithreading and SIMD optimization to achieve 60 fps or higher, despite running 3d physics entirely on the CPU

### Consequences

* Good, because using a 3d physics engine will allow users to be more detailed when configuring their robot
* Good, because a 3d simulation will more closely match reality
* Bad, because integrating Jolt Physics will be significantly more painful than a 2d alternative
