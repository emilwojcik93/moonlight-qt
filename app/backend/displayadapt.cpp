#include "displayadapt.h"

#include "settings/streamingpreferences.h"
#include "streaming/streamutils.h"

#include <QGuiApplication>
#include <QScreen>
#include <QWindow>

#include "SDL_compat.h"

namespace displayadapt {

QScreen* pickScreen(const StreamingPreferences* prefs, QScreen* windowScreen)
{
    switch (prefs->streamDisplay) {
    case StreamingPreferences::SD_WINDOW:
        return windowScreen;
    case StreamingPreferences::SD_NAMED:
        for (QScreen* screen : QGuiApplication::screens()) {
            if (screen->name() == prefs->streamDisplayName) {
                return screen;
            }
        }
        // Not connected now: the primary display
        return QGuiApplication::primaryScreen();
    case StreamingPreferences::SD_PRIMARY:
    default:
        return QGuiApplication::primaryScreen();
    }
}

int sdlDisplayForScreen(const QScreen* screen)
{
    if (screen == nullptr) {
        return -1;
    }

    const QRect displayRect = screen->geometry();
    for (int i = 0; i < SDL_GetNumVideoDisplays(); i++) {
        SDL_Rect displayBounds;

        if (SDL_GetDisplayBounds(i, &displayBounds) == 0) {
            if (displayBounds.x == displayRect.x() &&
                displayBounds.y == displayRect.y()) {
                return i;
            }
        }
        else {
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                        "SDL_GetDisplayBounds(%d) failed: %s",
                        i, SDL_GetError());
        }
    }
    return -1;
}

bool readDisplayMode(int sdlDisplayIndex, displayauto::DisplayMode& out)
{
    SDL_DisplayMode native;
    SDL_Rect safeArea;
    if (!StreamUtils::getNativeDesktopMode(sdlDisplayIndex, &native, &safeArea)) {
        return false;
    }

    out.width = native.w;
    out.height = native.h;
    out.refreshHz = native.refresh_rate;

    SDL_DisplayMode current;
    if (SDL_GetDesktopDisplayMode(sdlDisplayIndex, &current) == 0 && current.refresh_rate > 0) {
        out.refreshHz = current.refresh_rate;
    }
    return true;
}

std::optional<Result> compute(const StreamingPreferences* prefs, const displayauto::DisplayMode& display)
{
    const auto wanted = displayauto::chooseMode(display);
    if (!wanted) {
        return std::nullopt;
    }

    Result r;
    r.display = display;
    r.mode = *wanted;
    r.bitrateKbps = prefs->bitrateKbps;

    // PyroWave has its own bitrate scale
    if (prefs->videoCodecConfig != StreamingPreferences::VCC_FORCE_PYROWAVE) {
        const displayauto::StreamMode saved{prefs->width, prefs->height, prefs->fps};
        const bool yuv444 = prefs->enableYUV444;
        r.bitrateKbps = displayauto::chooseBitrate(
                    saved, prefs->bitrateKbps,
                    StreamingPreferences::getDefaultBitrate(saved.width, saved.height, saved.fps, yuv444),
                    r.mode,
                    StreamingPreferences::getDefaultBitrate(r.mode.width, r.mode.height, r.mode.fps, yuv444));
        r.bitrateAdapted = r.bitrateKbps != prefs->bitrateKbps;
    }
    return r;
}

} // namespace displayadapt

DisplayAdapt::DisplayAdapt(QObject* parent)
    : QObject(parent)
{
    m_Debounce.setSingleShot(true);
    m_Debounce.setInterval(400);
    connect(&m_Debounce, &QTimer::timeout, this, &DisplayAdapt::refresh);

    connect(qGuiApp, &QGuiApplication::screenAdded, this, [this](QScreen* screen) {
        watchScreen(screen);
        schedule();
    });
    connect(qGuiApp, &QGuiApplication::screenRemoved, this, &DisplayAdapt::schedule);
    connect(qGuiApp, &QGuiApplication::primaryScreenChanged, this, &DisplayAdapt::schedule);
    for (QScreen* screen : QGuiApplication::screens()) {
        watchScreen(screen);
    }

    // Everything the result depends on
    StreamingPreferences* prefs = StreamingPreferences::get();
    connect(prefs, &StreamingPreferences::autoAdaptDisplayChanged, this, &DisplayAdapt::schedule);
    connect(prefs, &StreamingPreferences::streamDisplayChanged, this, &DisplayAdapt::schedule);
    connect(prefs, &StreamingPreferences::streamDisplayNameChanged, this, &DisplayAdapt::schedule);
    connect(prefs, &StreamingPreferences::bitrateChanged, this, &DisplayAdapt::schedule);
    connect(prefs, &StreamingPreferences::enableYUV444Changed, this, &DisplayAdapt::schedule);
    connect(prefs, &StreamingPreferences::videoCodecConfigChanged, this, &DisplayAdapt::schedule);
}

void DisplayAdapt::watchScreen(QScreen* screen)
{
    connect(screen, &QScreen::geometryChanged, this, &DisplayAdapt::schedule);
    connect(screen, &QScreen::refreshRateChanged, this, &DisplayAdapt::schedule);
    connect(screen, &QScreen::physicalSizeChanged, this, &DisplayAdapt::schedule);
}

void DisplayAdapt::schedule()
{
    if (m_Active) {
        m_Debounce.start();
    }
}

void DisplayAdapt::setActive(bool active)
{
    if (m_Active == active) {
        return;
    }
    m_Active = active;
    emit activeChanged();
    if (active) {
        refresh();
    }
    else {
        m_Debounce.stop();
    }
}

void DisplayAdapt::refresh()
{
    if (SDL_InitSubSystem(SDL_INIT_VIDEO) != 0) {
        SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                     "SDL_InitSubSystem(SDL_INIT_VIDEO) failed: %s",
                     SDL_GetError());
        return;
    }

    const StreamingPreferences* prefs = StreamingPreferences::get();
    QScreen* const primary = QGuiApplication::primaryScreen();

    QVariantList displays;
    for (QScreen* screen : QGuiApplication::screens()) {
        displayauto::DisplayMode mode;
        const int sdlIndex = displayadapt::sdlDisplayForScreen(screen);
        if (sdlIndex < 0 || !displayadapt::readDisplayMode(sdlIndex, mode)) {
            // SDL and Qt disagree on where the screen is: Qt's own numbers
            mode.width = qRound(screen->size().width() * screen->devicePixelRatio());
            mode.height = qRound(screen->size().height() * screen->devicePixelRatio());
            mode.refreshHz = screen->refreshRate();
        }

        QString label = screen->name();
        const QString model = (screen->manufacturer() + QLatin1Char(' ') + screen->model()).trimmed();
        if (!model.isEmpty()) {
            label += QStringLiteral(" - ") + model;
        }

        QVariantMap entry;
        entry.insert(QStringLiteral("id"), screen->name());
        entry.insert(QStringLiteral("label"), label);
        entry.insert(QStringLiteral("primary"), screen == primary);
        entry.insert(QStringLiteral("width"), mode.width);
        entry.insert(QStringLiteral("height"), mode.height);
        entry.insert(QStringLiteral("refresh"), qRound(mode.refreshHz));
        displays.append(entry);
    }

    // What the stream would use: the Moonlight window is the first window's screen
    QScreen* windowScreen = nullptr;
    for (QWindow* window : QGuiApplication::topLevelWindows()) {
        if (window->isVisible()) {
            windowScreen = window->screen();
            break;
        }
    }
    QScreen* target = displayadapt::pickScreen(prefs, windowScreen ? windowScreen : primary);

    bool valid = false;
    QString targetName;
    QSize displaySize, streamSize;
    int displayRefresh = 0, streamFps = 0, bitrate = 0;

    if (target != nullptr) {
        displayauto::DisplayMode mode;
        const int sdlIndex = displayadapt::sdlDisplayForScreen(target);
        if (sdlIndex >= 0 && displayadapt::readDisplayMode(sdlIndex, mode)) {
            if (const auto result = displayadapt::compute(prefs, mode)) {
                valid = true;
                targetName = target->name();
                displaySize = QSize(mode.width, mode.height);
                displayRefresh = qRound(mode.refreshHz);
                streamSize = QSize(result->mode.width, result->mode.height);
                streamFps = result->mode.fps;
                bitrate = result->bitrateKbps;
            }
        }
    }

    SDL_QuitSubSystem(SDL_INIT_VIDEO);

    const bool differs = displays != m_Displays || valid != m_Valid || targetName != m_TargetName ||
                         displaySize != m_DisplaySize || displayRefresh != m_DisplayRefresh ||
                         streamSize != m_StreamSize || streamFps != m_StreamFps || bitrate != m_BitrateKbps;
    if (differs) {
        m_Displays = displays;
        m_Valid = valid;
        m_TargetName = targetName;
        m_DisplaySize = displaySize;
        m_DisplayRefresh = displayRefresh;
        m_StreamSize = streamSize;
        m_StreamFps = streamFps;
        m_BitrateKbps = bitrate;
        emit changed();
    }
}
