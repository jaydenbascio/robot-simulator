#include <catch2/catch_test_macros.hpp>
#include <engine/Simulator.h>
#include <utility>

TEST_CASE("Simulator Lifecycle", "[simulator]") {
    robotsimulator::engine::Simulator sim;
        
    SECTION("Initial State") {
        REQUIRE(sim.IsRunning());
    }

    SECTION("Update loop tick") {
        REQUIRE_NOTHROW(sim.Update(0.016));
        REQUIRE(sim.IsRunning());
    }

    SECTION("Termination") {
        // Simulate running the simulation for a single frame
        REQUIRE_NOTHROW(sim.Update(0.016));
        REQUIRE_NOTHROW(sim.Stop());
        REQUIRE_FALSE(sim.IsRunning());
    }
}

TEST_CASE("Simulator Delta Time Edge Cases", "[simulator]") {
    robotsimulator::engine::Simulator sim;

    SECTION("Zero Delta Time") {
        REQUIRE_NOTHROW(sim.Update(0.0));
        REQUIRE(sim.IsRunning());
    }

    SECTION("Negative Delta Time") {
        REQUIRE_NOTHROW(sim.Update(-1.5));
        REQUIRE(sim.IsRunning());
    }

    SECTION("Large Delta Time") {
        REQUIRE_NOTHROW(sim.Update(1000.0));
        REQUIRE(sim.IsRunning());
    }
}

TEST_CASE("Simulator Stop Repeatability", "[simulator]") {
    robotsimulator::engine::Simulator sim;

    SECTION("Stop multiple times") {
        REQUIRE(sim.IsRunning());

        REQUIRE_NOTHROW(sim.Stop());
        REQUIRE_FALSE(sim.IsRunning());
        
        REQUIRE_NOTHROW(sim.Stop());
        REQUIRE_FALSE(sim.IsRunning());
    }
}

TEST_CASE("Simulator Move Operations", "[simulator]") {
    SECTION("Move Constructor") {
        robotsimulator::engine::Simulator original;
        REQUIRE(original.IsRunning());

        robotsimulator::engine::Simulator moved(std::move(original));
        
        // The moved-to simulator should be running too
        REQUIRE(moved.IsRunning());
    }

    SECTION("Move Assignment") {
        robotsimulator::engine::Simulator original;
        REQUIRE(original.IsRunning());
        
        robotsimulator::engine::Simulator moved;
        moved.Stop();
        REQUIRE_FALSE(moved.IsRunning());

        moved = std::move(original);

        // After move assignment, moved-to simulator should be running (since original was running)
        REQUIRE(moved.IsRunning());
    }
}

