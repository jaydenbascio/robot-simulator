#ifndef ENGINE_SIMULATOR_H
#define ENGINE_SIMULATOR_H

#include <memory>

namespace robotsimulator::engine {

class Simulator {
public:
	Simulator();
	~Simulator();

	Simulator(const Simulator&) = delete;
	Simulator& operator=(const Simulator&) = delete;
	Simulator(Simulator&&) noexcept;
	Simulator& operator=(Simulator&&) noexcept;

	/**
	 * @brief Update the simulation by one time step; iterate through one frame
	 *
	 * @param deltaTime The time in seconds since the last frame
	 */
	void Update(double deltaTime);

	/**
	 * @brief Check if the simulation is actively running
	 * @return Whether or not the simulation is actively running
	 */
	bool IsRunning() const;

	/**
	 * @brief Terminate the simulation for good
	 * @note Should be called when the window closes or the simulation reaches its end (may be an unexpected error)
	 */
	void Stop();

private:
	struct Impl;
	std::unique_ptr<Impl> m_Impl;
};

} // namespace robotsimulator::engine

#endif // ENGINE_SIMULATOR_H
