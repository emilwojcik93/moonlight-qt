#pragma once

#include <QMutex>
#include <QSslCertificate>
#include <QThread>

#include <atomic>
#include <chrono>
#include <optional>

#include "backend/nvaddress.h"
#include "backend/postureclassifier.h"

// Watches the client posture while a stream runs, tells the host when it
// changes (2-in-1 flipped to tablet, keyboard detached, ...) and says when the
// stream should be resumed so the host rebuilds its virtual display.
//
// The Qt event loop of the GUI thread is not pumped during a stream and the SDL
// loop must never block, so the work lives on a worker thread with its own
// event loop. Two sources feed it:
//   - tabletModeChanged D-Bus events (Linux/KDE), handled immediately;
//   - tick(), called from the SDL loop, which takes a cheap non-blocking sample
//     of the local signals once a second. The worker adds the OS tablet-mode
//     state (a D-Bus call that can block) on each sample. This is the fallback
//     and the only source on Windows.
// Changes are debounced for a short time, sent as /posture (failures are
// ignored), and an accepted boundary crossing then makes restartDue() true.
class PostureMonitor : public QThread
{
public:
    static constexpr std::chrono::milliseconds kSampleInterval{1000};
    static constexpr std::chrono::milliseconds kDebounce{1000};

    // launchPayload is what the launch/resume request carried (possibly
    // invalid, meaning nothing was sent), the baseline for change detection and
    // for the restart decision. restartEnabled is the user setting and
    // lastRestart the time of the previous automatic restart, if any.
    PostureMonitor(posture::Mode mode,
                   const posture::Payload& launchPayload,
                   NvAddress address,
                   uint16_t httpsPort,
                   QSslCertificate serverCert,
                   bool useTrueUid,
                   bool restartEnabled,
                   std::optional<std::chrono::steady_clock::time_point> lastRestart);
    ~PostureMonitor() override;

    // SDL loop thread only. Cheap; never blocks on I/O.
    void tick();

    // Any thread. True once the host accepted a posture change that needs a
    // new virtual display and the restart rules (cooldown, ...) allow it.
    bool restartDue() const { return m_RestartDue.load(); }

protected:
    void run() override;

private:
    posture::Mode m_Mode;
    posture::Payload m_LaunchPayload;
    NvAddress m_Address;
    uint16_t m_HttpsPort;
    QSslCertificate m_ServerCert;
    bool m_UseTrueUid;
    bool m_RestartEnabled;
    std::optional<std::chrono::steady_clock::time_point> m_LastRestart;
    std::chrono::steady_clock::time_point m_Started;

    std::chrono::steady_clock::time_point m_NextSample;

    std::atomic<bool> m_Stop{false};
    std::atomic<bool> m_RestartDue{false};

    QMutex m_Mutex;
    bool m_HasSample = false;
    posture::Signals m_Sample;
};
