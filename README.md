# Robot Simulator

This project aims to provide a developer friendly interface for developing and testing algorithms used in robotics competitions such as Vex V5.

## Directory Structure

This project uses the Pitchfork Layout for modular development. Submodules are designed as self-contained units under `libs/`, and user-facing applications are located under `apps/`.

```
├─ apps/
│  └─ simulator_gui/       # Graphical simulator application executable
│     ├─ src/              # App entry points
│     └─ CMakeLists.txt
├─ libs/
│  ├─ lib1/                # Library that includes use unit tests (like the core engine)
│  │  ├─ include/lib1/     # Public API headers
│  │  ├─ src/              # Private implementation files
│  │  ├─ tests/            # Unit tests for the engine
│  │  └─ CMakeLists.txt
│  └─ lib2/                # Library that does not use unit tests (like ui or graphics)
│     ├─ include/lib2/     # Public API headers
│     ├─ src/              # Private implementation files
│     └─ CMakeLists.txt
├─ cmake/                  # Custom CMake configuration
├─ CMakeLists.txt          # Root build configuration
├─ CMakePresets.json       # Configured build presets
├─ vcpkg.json              # vcpkg package manifest
└─ ...                     # Other configuration / documentation files
```

---

## Developer Onboarding & Getting Started

### Option 1: Windows with VS Code

1. **Run the Setup Script**
   * Download and run the setup script under `setup.ps1` to setup your computer for development on this project. Keep in mind this requires Administrator rights
   * This script will install all of the prerequisites required for the project using Chocolately, including VS Code and Git. It will also clone the repository and ensure that it builds successfully.

2. **Configure & Build**:
   * Run the following commands to build the application under `debug` mode.
      ```cmd
      cmake --preset debug
      cmake --build --preset debug-build
      ```
   * The following command will run unit tests on the project:
      ```cmd
      ctest --preset debug-test
      ```

3. **Run the Application**
   * Run the application under `./build/debug/apps/simulator_gui/simulator_gui.exe`

---

### Option 2: Linux / macOS / Manual Setup
1. **Install prerequisites**
   * Install the prerequisites required for developing on this project:
      * Git
      * Clang / LLVM (20.1.8)
      * CMake (4.3.4)
      * Ninja (1.13.2)
2. **Clone the Repository**:
   * Run the following command to clone this repository:
   ```bash
   git clone https://github.com/jaydenbascio/robot-simulator
   ```
3. **Configure & Build**:
   * Run the following commands to build the application under `debug` mode.
      ```bash
      cmake --preset debug
      cmake --build --preset debug-build
      ```
   * The following command will run unit tests on the project:
      ```bash
      ctest --preset debug-test
      ```

3. **Run the Application**
   * Run the application under `/build/debug/apps/simulator_gui/simulator_gui.exe`

---

## Tech Stack
- **Language**: C++17
- **Compiler**: Clang
- **Graphics Framework**: SDL3 (managed via vcpkg)
- **Test Framework**: Catch2 (managed via vcpkg)
- **Build System**: CMake & Ninja
