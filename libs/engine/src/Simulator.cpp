#include <engine/Simulator.h>

namespace robotsimulator::engine {

struct Simulator::Impl {
    bool isRunning;

    Impl() : isRunning(true) {}
};

Simulator::Simulator() : m_Impl(std::make_unique<Impl>()) {}

Simulator::~Simulator() = default;
Simulator::Simulator(Simulator&&) noexcept = default;
Simulator& Simulator::operator=(Simulator&&) noexcept = default;

bool Simulator::IsRunning() const { return m_Impl->isRunning; }

void Simulator::Update(double deltaTime) {
    /* TODO: Implement simulator logic */
    (void)deltaTime;
}

void Simulator::Stop() { m_Impl->isRunning = false; }

} // namespace robotsimulator::engine
