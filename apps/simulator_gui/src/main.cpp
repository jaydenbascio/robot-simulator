#include <engine/Simulator.h>
#include <robotsimulator/version.h>
#include <ui/Renderer2D.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <stdexcept>

int main(int argc, char* argv[]) {
    (void)argc;
    (void)argv;

    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)) {
        SDL_Log("Failed to initialize SDL3!");
        return EXIT_FAILURE;
    }

    SDL_Log("Starting Robot Simulator v%s (Major: %d, Minor: %d, Patch: %d)", ROBOTSIMULATOR_VERSION,
            ROBOTSIMULATOR_VERSION_MAJOR, ROBOTSIMULATOR_VERSION_MINOR, ROBOTSIMULATOR_VERSION_PATCH);

    // Initialize the renderer and simulator
    robotsimulator::ui::Renderer2D renderer("MCL Simulator", 600, 400);
    robotsimulator::engine::Simulator simulator;

    // Delta Time calculation variables
    Uint64 now = SDL_GetPerformanceCounter();
    Uint64 last = 0;

    while (simulator.IsRunning()) {
        // Calculate deltaTime using SDL3
        last = now;
        now = SDL_GetPerformanceCounter();
        double deltaTime = static_cast<double>(now - last) / static_cast<double>(SDL_GetPerformanceFrequency());

        // Poll and deal with events using SDL3
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT || event.type == SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
                simulator.Stop();
            }
        }

        // Update simulator logic
        simulator.Update(deltaTime);

        // Render frame
        renderer.Clear();
        renderer.Present();
    }

    SDL_Quit();
    return 0;
}
