#include "posturemonitor.h"

#include "backend/nvhttp.h"
#include "backend/posturedetector.h"

#include <QDebug>
#include <QTimer>

PostureMonitor::PostureMonitor(posture::Mode mode,
                               const posture::Payload& launchPayload,
                               NvAddress address,
                               uint16_t httpsPort,
                               QSslCertificate serverCert,
                               bool useTrueUid,
                               bool restartEnabled,
                               std::optional<std::chrono::steady_clock::time_point> lastRestart)
    : QThread(nullptr),
      m_Mode(mode),
      m_LaunchPayload(launchPayload),
      m_Address(address),
      m_HttpsPort(httpsPort),
      m_ServerCert(serverCert),
      m_UseTrueUid(useTrueUid),
      m_RestartEnabled(restartEnabled),
      m_LastRestart(lastRestart),
      m_Started(std::chrono::steady_clock::now()),
      m_NextSample(m_Started + kSampleInterval)
{
    setObjectName("Posture Monitor");
    start();
}

PostureMonitor::~PostureMonitor()
{
    m_Stop = true;
    quit();
    wait();
}

void PostureMonitor::tick()
{
    const auto now = std::chrono::steady_clock::now();
    if (now < m_NextSample) {
        return;
    }
    m_NextSample = now + kSampleInterval;

    // Touch devices: GUI thread, non-blocking
    const posture::Signals sample = posture::collectLocalSignals();
    QMutexLocker lock(&m_Mutex);
    m_Sample = sample;
    m_HasSample = true;
}

void PostureMonitor::run()
{
    NvHTTP http(m_Address, m_HttpsPort, m_ServerCert, m_UseTrueUid);
    posture::UpdateGate gate(m_LaunchPayload, kDebounce);
    posture::RestartGate restart(m_RestartEnabled, m_LaunchPayload, m_Started, m_LastRestart);

    posture::Signals local;
    bool haveLocal = false;
    std::optional<bool> osTablet;
    std::optional<bool> osTabletAvailable;
    bool busy = false;

    // Pure decision step: no I/O except the /posture call itself. Safe to run
    // as often as we like; the gates hold the debounce and restart rules.
    auto evaluate = [&]() {
        // updatePosture() runs a nested event loop; do not re-enter from it
        if (busy || !haveLocal) {
            return;
        }
        busy = true;

        posture::Signals sample = local;
        sample.osTabletMode = osTablet;
        sample.osTabletModeAvailable = osTabletAvailable;
        const posture::Payload current = posture::makePayload(sample, m_Mode, true);
        const auto now = std::chrono::steady_clock::now();
        if (const auto update = gate.observe(current, now)) {
            const QString query = QString::fromStdString(posture::buildQuery(*update));
            qInfo().noquote() << "Client posture changed, notifying host:" << query;
            try {
                const std::optional<bool> displayChange = http.updatePosture(query);
                restart.accepted(*update, displayChange);
                if (displayChange && !*displayChange) {
                    qInfo() << "Host switched mode without a new display; no stream restart needed";
                }
            } catch (const std::exception& e) {
                qDebug() << "Posture update ignored:" << e.what();
            } catch (...) {
                qDebug() << "Posture update ignored";
            }
        }

        if (!m_RestartDue.load() && restart.due(std::chrono::steady_clock::now())) {
            qInfo() << "Posture change needs a new host display; stream restart requested";
            m_RestartDue = true;
        }
        busy = false;
    };

    // Event source: KWin tabletModeChanged. Marshalled onto this thread's loop.
    posture::TabletModeWatcher watcher([&](bool tabletMode) {
        osTablet = tabletMode;
        evaluate();
    });
    qDebug() << "Posture tablet-mode events:" << (watcher.active() ? "subscribed" : "not available, sampling only");

    // Sampling source and debounce clock
    QTimer timer;
    timer.setInterval(250);
    QObject::connect(&timer, &QTimer::timeout, &timer, [&]() {
        if (m_Stop) {
            quit();
            return;
        }

        bool fresh = false;
        {
            QMutexLocker lock(&m_Mutex);
            if (m_HasSample) {
                local = m_Sample;
                m_HasSample = false;
                haveLocal = fresh = true;
            }
        }
        if (fresh) {
            // Blocking D-Bus read (or Win32 metric), at most once a second
            posture::Signals probe = local;
            posture::collectOsTabletSignals(probe);
            osTablet = probe.osTabletMode;
            osTabletAvailable = probe.osTabletModeAvailable;
        }
        evaluate();
    });
    timer.start();

    exec();
}
