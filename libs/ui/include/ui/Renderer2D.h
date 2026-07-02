#ifndef UI_RENDERER2D_H
#define UI_RENDERER2D_H

#include <memory>
#include <cstdint>

namespace robotsimulator::ui {

/**
 * @brief Deals with the SDL3 window and renderer, abstracting the graphics to basic functions for drawing
 * @note This class does NOT manage SDL3 initialization and cleanup, such as SDL_Init or SDL_Quit.
 */
class Renderer2D {
public:
	Renderer2D(const char* title, int width, int height);
	~Renderer2D();

	Renderer2D(Renderer2D&&) = delete;
	Renderer2D& operator=(Renderer2D&&) = delete;

	/**
	 * @brief Clears the screen to a uniform color.
	 *
	 * @note Clear color is configurable with SetClearColor(), which acts as the "background color" of the window.
	 * @note Should be called at the start of the render frame.
	 */
	void Clear();

	/**
	 * @brief Displays the backbuffer of the SDL3 renderer to the screen
	 *
	 * @note Should be called at the end of the render frame
	 */
	void Present();

	/**
	 * @brief Sets the clear color of the SDL3 renderer, effectively acting as a "background color" when used by Clear()
	 *
	 * @param red The red component of the clear color
	 * @param green The green component of the clear color
	 * @param blue The blue component of the clear color
	 */
	void SetClearColor(std::uint8_t red, std::uint8_t green, std::uint8_t blue, std::uint8_t alpha = 255);

private:
	struct Impl;
	std::unique_ptr<Impl> m_Impl;
};

} // namespace robotsimulator::ui

#endif // UI_RENDERER2D_H
