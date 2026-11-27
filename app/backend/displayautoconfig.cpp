#include "displayautoconfig.h"

#include <algorithm>
#include <cmath>

namespace displayauto {

int snapFps(double refreshHz, const Limits& limits)
{
    static const int kRates[] = { 30, 50, 60, 75, 90, 100, 120, 144, 165, 240 };

    // Panels report 59.94 or 143.98; compare against the rounded value
    const int rounded = static_cast<int>(std::lround(refreshHz));
    int best = limits.minFps;
    for (int rate : kRates) {
        if (rate <= rounded && rate <= limits.maxFps && rate >= limits.minFps) {
            best = rate;
        }
    }

    // A rate well above the nearest standard one (a 48 Hz power-saving mode)
    // is used as it is instead of dropping to 30
    if (rounded > best && rounded - best > 10 && rounded <= limits.maxFps) {
        best = rounded;
    }
    return std::min(best, limits.maxFps);
}

std::optional<StreamMode> chooseMode(const DisplayMode& display, const Limits& limits)
{
    if (display.width <= 0 || display.height <= 0) {
        return std::nullopt;
    }

    // Always landscape: turning a tablet must not change the stream's shape (and
    // restart it); the video is letterboxed in a portrait window
    int w = std::max(display.width, display.height);
    int h = std::min(display.width, display.height);
    if (w > limits.maxWidth || h > limits.maxHeight) {
        // Fit inside the cap and keep the aspect ratio
        const double scale = std::min(static_cast<double>(limits.maxWidth) / w,
                                      static_cast<double>(limits.maxHeight) / h);
        w = static_cast<int>(w * scale);
        h = static_cast<int>(h * scale);
    }

    StreamMode m;
    m.width = w & ~1;
    m.height = h & ~1;
    m.fps = snapFps(display.refreshHz > 0 ? display.refreshHz : 60.0, limits);
    return m;
}

int chooseBitrate(const StreamMode& savedMode,
                  int savedBitrate,
                  int defaultForSaved,
                  const StreamMode& newMode,
                  int defaultForNew)
{
    if (savedMode == newMode) {
        return savedBitrate;
    }

    // Within 5 % of the default for the saved mode: the user never changed it
    const bool isDefault = defaultForSaved > 0 &&
                           std::abs(savedBitrate - defaultForSaved) <= defaultForSaved / 20;
    if (isDefault) {
        return defaultForNew;
    }

    if (defaultForSaved <= 0) {
        return savedBitrate;
    }
    const double ratio = std::clamp(static_cast<double>(defaultForNew) / defaultForSaved, 0.4, 1.0);
    return std::max(1000, static_cast<int>(std::lround(savedBitrate * ratio)));
}

AdaptGate::AdaptGate(std::chrono::milliseconds debounce,
                     std::chrono::milliseconds cooldown,
                     std::optional<Clock::time_point> lastRestart)
    : m_Debounce(debounce), m_Cooldown(cooldown), m_LastRestart(lastRestart)
{
}

bool AdaptGate::update(const StreamMode& wanted, const StreamMode& active, Clock::time_point now)
{
    if (wanted == active) {
        m_Pending.reset();
        return false;
    }

    if (!m_Pending || *m_Pending != wanted) {
        // A new difference, or the display changed again: restart the debounce
        m_Pending = wanted;
        m_PendingSince = now;
        return false;
    }

    if (now - m_PendingSince < m_Debounce) {
        return false;
    }
    if (m_LastRestart && now - *m_LastRestart < m_Cooldown) {
        return false;
    }

    m_LastRestart = now;
    m_Pending.reset();
    return true;
}

} // namespace displayauto
