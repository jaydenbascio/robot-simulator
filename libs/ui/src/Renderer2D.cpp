#include <ui/Renderer2D.h>

#include <SDL3/SDL.h>

#include <array>
#include <stdexcept>

namespace robotsimulator::ui {

struct SDLWindowDeleter {
	void operator()(SDL_Window* w) const {
		if (w) SDL_DestroyWindow(w);
	}
};

struct SDLRendererDeleter {
	void operator()(SDL_Renderer* r) const {
		if (r) SDL_DestroyRenderer(r);
	}
};

using SDLWindow = std::unique_ptr<SDL_Window, SDLWindowDeleter>;
using SDLRenderer = std::unique_ptr<SDL_Renderer, SDLRendererDeleter>;

constexpr SDL_Color kDefaultClearColor{ 117, 124, 136, 255 };

struct Renderer2D::Impl {
	SDLWindow window;
	SDLRenderer renderer;

	SDL_Color clearColor{ kDefaultClearColor };
};

Renderer2D::Renderer2D(const char* title, int width, int height)
	: m_Impl(std::make_unique<Impl>()) {
	// Initialize the window and renderer
	m_Impl->window = SDLWindow(SDL_CreateWindow(title, width, height, 0));
	if (!m_Impl->window) {
		throw std::runtime_error("Failed to initialize SDL Window");
	}

	m_Impl->renderer = SDLRenderer(SDL_CreateRenderer(m_Impl->window.get(), nullptr));
	if (!m_Impl->renderer) {
		throw std::runtime_error("Failed to initialize SDL Renderer");
	}
}

Renderer2D::~Renderer2D() = default;

void Renderer2D::Clear() {
	// Set clear color to the configured color
	if (!SDL_SetRenderDrawColor(
		m_Impl->renderer.get(),
		m_Impl->clearColor.r,
		m_Impl->clearColor.g,
		m_Impl->clearColor.b,
		m_Impl->clearColor.a
	)
		) {
		SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Failed to set render draw color: %s", SDL_GetError());
	}

	// Clear the screen
	if (!SDL_RenderClear(m_Impl->renderer.get())) {
		SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Failed to clear renderer: %s", SDL_GetError());
	}
}

void Renderer2D::Present() {
	if (!SDL_RenderPresent(m_Impl->renderer.get())) {
		SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Failed to present renderer: %s", SDL_GetError());
	}
}

void Renderer2D::SetClearColor(std::uint8_t red, std::uint8_t green, std::uint8_t blue, std::uint8_t alpha) {
	m_Impl->clearColor = { red, green, blue, alpha };
}

} // namespace robotsimulator::ui
