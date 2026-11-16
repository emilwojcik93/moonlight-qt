#pragma once

#include "postureclassifier.h"

// Gathers the local signals that posture::classify() consumes. No monitor
// model, EDID or host data is read; every value comes from the OS or Qt.
namespace posture {

// Non-blocking: Qt input devices, primary screen metrics, chassis type.
// Call from the GUI thread (Qt's device list is not thread safe). Never
// reports a diagonal/DPI unless the screen gave a plausible physical size.
Signals collectLocalSignals();

// OS tablet/slate-mode state. May block briefly (KWin D-Bus, 500 ms cap), so
// call it off the GUI/stream thread. Leaves the fields unset when the OS has
// no such signal or the build lacks the feature.
//   Linux/KDE: org.kde.KWin /org/kde/KWin org.kde.KWin.TabletModeManager
//   Windows:   GetSystemMetrics(SM_CONVERTIBLESLATEMODE), 0 == slate
void collectOsTabletSignals(Signals& out);

} // namespace posture
