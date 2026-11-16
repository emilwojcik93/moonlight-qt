#include "posturemonitor.h"

#include "backend/nvhttp.h"
#include "backend/posturedetector.h"

#include <QDebug>

PostureMonitor::PostureMonitor(posture::Mode mode,
                               const posture::Payload& launchPayload,
                               NvAddress address,
                               uint16_t httpsPort,
                               QSslCertificate serverCert,
                               bool useTrueUid)
    : QThread(nullptr),
      m_Mode(mode),
      m_LaunchPayload(launchPayload),
      m_Address(address),
      m_HttpsPort(httpsPort),
      m_ServerCert(serverCert),
      m_UseTrueUid(useTrueUid),
      m_NextSample(std::chrono::steady_clock::now() + kSampleInterval)
{
    setObjectName("Posture Monitor");
    start();
}

PostureMonitor::~PostureMonitor()
{
    {
        QMutexLocker lock(&m_Mutex);
        m_Stop = true;
    }
    m_Wake.wakeAll();
    wait();
}

void PostureMonitor::tick()
{
    const auto now = std::chrono::steady_clock::now();
    if (now < m_NextSample) {
        return;
    }
    m_NextSample = now + kSampleInterval;

    // Touch devices and screen metrics: GUI thread, non-blocking
    const posture::Signals sample = posture::collectLocalSignals();
    {
        QMutexLocker lock(&m_Mutex);
        m_Sample = sample;
        m_HasSample = true;
    }
    m_Wake.wakeOne();
}

void PostureMonitor::run()
{
    NvHTTP http(m_Address, m_HttpsPort, m_ServerCert, m_UseTrueUid);
    posture::UpdateGate gate(m_LaunchPayload, kDebounce);

    QMutexLocker lock(&m_Mutex);
    while (!m_Stop) {
        if (!m_HasSample) {
            m_Wake.wait(&m_Mutex);
            continue;
        }

        posture::Signals sample = m_Sample;
        m_HasSample = false;
        lock.unlock();

        posture::collectOsTabletSignals(sample);
        const posture::Payload current = posture::makePayload(sample, m_Mode, true);
        if (const auto update = gate.observe(current, std::chrono::steady_clock::now())) {
            const QString query = QString::fromStdString(posture::buildQuery(*update));
            qInfo().noquote() << "Client posture changed, notifying host:" << query;
            try {
                http.updatePosture(query);
            } catch (const std::exception& e) {
                qDebug() << "Posture update ignored:" << e.what();
            } catch (...) {
                qDebug() << "Posture update ignored";
            }
        }

        lock.relock();
    }
}
