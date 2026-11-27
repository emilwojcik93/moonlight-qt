#pragma once

#include <chrono>
#include <optional>

// Picks the stream mode (resolution, frame rate, bitrate) that suits the display
// the stream is shown on. Pure code: the caller reads the display and the saved
// preferences and applies the result; nothing here touches SDL or Qt.
namespace displayauto {

struct DisplayMode {
    int width = 0;
    int height = 0;
    double refreshHz = 0;
};

struct StreamMode {
    int width = 0;
    int height = 0;
    int fps = 0;

    bool operator==(const StreamMode& o) const
    {
        return width == o.width && height == o.height && fps == o.fps;
    }
    bool operator!=(const StreamMode& o) const { return !(*this == o); }
};

struct Limits {
    int maxWidth = 3840;
    int maxHeight = 2160;
    int maxFps = 144;
    int minFps = 30;
};

// Resolution and frame rate for a display. Returns nothing when the display
// mode is unusable (zero size), so the caller keeps its saved values.
std::optional<StreamMode> chooseMode(const DisplayMode& display, const Limits& limits = Limits());

// Largest standard frame rate not above the refresh rate (59.94 -> 60,
// 143.98 -> 144, 74.97 -> 75), within the limits.
int snapFps(double refreshHz, const Limits& limits = Limits());

// Bitrate for a new mode. savedBitrate belongs to savedMode. defaultForSaved and
// defaultForNew are Moonlight's own default bitrates for the two modes.
// - same mode: unchanged
// - saved bitrate is the default of the saved mode (never changed): the default
//   of the new mode
// - user-set bitrate: scaled by the ratio of the defaults, limited to 0.4x..1.0x.
//   A bitrate the user chose is treated as the ceiling of their link: it is
//   lowered for a smaller display, never raised for a bigger one
int chooseBitrate(const StreamMode& savedMode,
                  int savedBitrate,
                  int defaultForSaved,
                  const StreamMode& newMode,
                  int defaultForNew);

// Debounce and cooldown for restarting a running stream when the wanted mode
// differs from the active one. Feed it the current wanted/active modes about
// once a second; update() returns true once when a restart is due.
class AdaptGate {
public:
    using Clock = std::chrono::steady_clock;

    AdaptGate(std::chrono::milliseconds debounce,
              std::chrono::milliseconds cooldown,
              std::optional<Clock::time_point> lastRestart = std::nullopt);

    bool update(const StreamMode& wanted, const StreamMode& active, Clock::time_point now);

private:
    std::chrono::milliseconds m_Debounce;
    std::chrono::milliseconds m_Cooldown;
    std::optional<Clock::time_point> m_LastRestart;
    std::optional<StreamMode> m_Pending;
    Clock::time_point m_PendingSince;
};

} // namespace displayauto
