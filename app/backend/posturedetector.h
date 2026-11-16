#pragma once

#include "postureclassifier.h"

#include <QObject>

#include <functional>

// Gathers the local signals that posture::classify() consumes. No monitor
// model, EDID, size or host data is read; every value comes from the OS or Qt.
namespace posture {

// Non-blocking: Qt input devices and chassis type. Call from the GUI thread
// (Qt's device list is not thread safe). Screen size and DPI are never read.
Signals collectLocalSignals();

// OS tablet/slate-mode state. May block briefly (KWin D-Bus, 500 ms cap), so
// call it off the GUI/stream thread. Leaves the fields unset when the OS has
// no such signal or the build lacks the feature.
//   Linux/KDE: org.kde.KWin /org/kde/KWin org.kde.KWin.TabletModeManager
//   Windows:   GetSystemMetrics(SM_CONVERTIBLESLATEMODE), 0 == slate
void collectOsTabletSignals(Signals& out);

// Event-driven tablet-mode source: calls onChange(tabletMode) from the thread
// that owns this object (which must run a Qt event loop) whenever the OS says
// tablet mode changed. Linux/KDE subscribes to the KWin TabletModeManager
// tabletModeChanged D-Bus signal; elsewhere (and in builds without QtDBus) it
// is inert and the caller's periodic sampling is the only source. Windows has
// no cheap hook without a window of our own, so it samples
// SM_CONVERTIBLESLATEMODE once a second instead of reacting to WM_SETTINGCHANGE.
class TabletModeWatcher : public QObject
{
    Q_OBJECT

public:
    explicit TabletModeWatcher(std::function<void(bool)> onChange);

    // True when an event subscription is active.
    bool active() const { return m_Active; }

private slots:
    void onTabletModeChanged(bool tabletMode);

private:
    std::function<void(bool)> m_OnChange;
    bool m_Active = false;
};

} // namespace posture
