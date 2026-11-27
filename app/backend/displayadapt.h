#pragma once

#include "backend/displayautoconfig.h"

#include <QObject>
#include <QSize>
#include <QString>
#include <QTimer>
#include <QVariantList>

#include <optional>

class QScreen;
class StreamingPreferences;

// Shared by the stream session and the settings page, so the settings show the
// numbers the next stream will really use.
namespace displayadapt {

struct Result {
    displayauto::DisplayMode display;
    displayauto::StreamMode mode;
    int bitrateKbps = 0;
    bool bitrateAdapted = false;
};

// The Qt screen the stream is shown on, per the stream-display preference.
// windowScreen is the Moonlight window's screen (used for "Moonlight window").
QScreen* pickScreen(const StreamingPreferences* prefs, QScreen* windowScreen);

// The SDL display that sits where the Qt screen sits, or -1. SDL video must be
// initialised.
int sdlDisplayForScreen(const QScreen* screen);

// Native pixels of an SDL display (Moonlight's own "native" choice) and the
// refresh rate of the mode the desktop runs in now. SDL video must be initialised.
bool readDisplayMode(int sdlDisplayIndex, displayauto::DisplayMode& out);

// Stream mode and bitrate for a display, with the saved video settings as the
// reference. Nothing when the display mode is unusable.
std::optional<Result> compute(const StreamingPreferences* prefs, const displayauto::DisplayMode& display);

} // namespace displayadapt

// Live view for the settings page: connected displays and what "Adapt to the
// display" would use now. Updates when displays or the relevant settings change.
class DisplayAdapt : public QObject
{
    Q_OBJECT

    // Only refresh while the settings page is visible (SDL is started per refresh)
    Q_PROPERTY(bool active MEMBER m_Active WRITE setActive NOTIFY activeChanged)

    // [{id, label, primary, width, height, refresh}]
    Q_PROPERTY(QVariantList displays MEMBER m_Displays NOTIFY changed)

    Q_PROPERTY(bool valid MEMBER m_Valid NOTIFY changed)
    Q_PROPERTY(QString targetName MEMBER m_TargetName NOTIFY changed)
    Q_PROPERTY(QSize displaySize MEMBER m_DisplaySize NOTIFY changed)
    Q_PROPERTY(int displayRefresh MEMBER m_DisplayRefresh NOTIFY changed)
    Q_PROPERTY(QSize streamSize MEMBER m_StreamSize NOTIFY changed)
    Q_PROPERTY(int streamFps MEMBER m_StreamFps NOTIFY changed)
    Q_PROPERTY(int bitrateKbps MEMBER m_BitrateKbps NOTIFY changed)

public:
    explicit DisplayAdapt(QObject* parent = nullptr);

    Q_INVOKABLE void refresh();

    void setActive(bool active);

signals:
    void changed();
    void activeChanged();

private:
    void schedule();
    void watchScreen(QScreen* screen);

    QTimer m_Debounce;
    bool m_Active = false;
    QVariantList m_Displays;
    bool m_Valid = false;
    QString m_TargetName;
    QSize m_DisplaySize;
    int m_DisplayRefresh = 0;
    QSize m_StreamSize;
    int m_StreamFps = 0;
    int m_BitrateKbps = 0;
};
