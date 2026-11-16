#pragma once

#include <QMutex>
#include <QSslCertificate>
#include <QThread>
#include <QWaitCondition>

#include <chrono>

#include "backend/nvaddress.h"
#include "backend/postureclassifier.h"

// Watches the client posture while a stream runs and tells the host when it
// changes (2-in-1 flipped to tablet, keyboard detached, ...).
//
// The Qt event loop is not pumped during a stream and the SDL loop must never
// block, so the work is split: tick() is called from the SDL loop, takes a
// cheap non-blocking sample of the local signals once a second and hands it to
// a worker thread. The worker adds the OS tablet-mode state (a D-Bus call that
// can block), debounces, and sends /posture. Failures are ignored.
class PostureMonitor : public QThread
{
public:
    static constexpr std::chrono::milliseconds kSampleInterval{1000};
    static constexpr std::chrono::milliseconds kDebounce{3000};

    // launchPayload is what the launch/resume request carried (possibly
    // invalid, meaning nothing was sent), the baseline for change detection.
    PostureMonitor(posture::Mode mode,
                   const posture::Payload& launchPayload,
                   NvAddress address,
                   uint16_t httpsPort,
                   QSslCertificate serverCert,
                   bool useTrueUid);
    ~PostureMonitor() override;

    // SDL loop thread only. Cheap; never blocks on I/O.
    void tick();

protected:
    void run() override;

private:
    posture::Mode m_Mode;
    posture::Payload m_LaunchPayload;
    NvAddress m_Address;
    uint16_t m_HttpsPort;
    QSslCertificate m_ServerCert;
    bool m_UseTrueUid;

    std::chrono::steady_clock::time_point m_NextSample;

    QMutex m_Mutex;
    QWaitCondition m_Wake;
    bool m_Stop = false;
    bool m_HasSample = false;
    posture::Signals m_Sample;
};
