#include "posturedetector.h"

#include <QtGlobal>
#include <QString>

#include <cmath>

#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
#include <QGuiApplication>
#include <QInputDevice>
#include <QScreen>
#endif

#ifdef Q_OS_LINUX
#include <QFile>
#endif

#ifdef HAVE_POSTURE_DBUS
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusVariant>
#endif

#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace posture {

#ifdef Q_OS_LINUX
// SMBIOS chassis types: https://www.dmtf.org/standards/smbios (System Enclosure)
static std::optional<bool> chassisIsPortable()
{
    QFile f("/sys/class/dmi/id/chassis_type");
    if (!f.open(QIODevice::ReadOnly)) {
        return std::nullopt;
    }
    bool ok = false;
    const int type = QString::fromUtf8(f.readAll()).trimmed().toInt(&ok);
    if (!ok) {
        return std::nullopt;
    }
    switch (type) {
    case 8:   // Portable
    case 9:   // Laptop
    case 10:  // Notebook
    case 11:  // Handheld
    case 14:  // Sub Notebook
    case 30:  // Tablet
    case 31:  // Convertible
    case 32:  // Detachable
        return true;
    case 3:   // Desktop
    case 4:   // Low Profile Desktop
    case 5:   // Pizza Box
    case 6:   // Mini Tower
    case 7:   // Tower
    case 13:  // All in One
    case 15:  // Space-saving
    case 16:  // Lunch Box
    case 17:  // Main Server Chassis
    case 23:  // Rack Mount Chassis
    case 24:  // Sealed-case PC
    case 34:  // Embedded PC
    case 35:  // Mini PC
    case 36:  // Stick PC
        return false;
    default:  // Other/Unknown/virtual
        return std::nullopt;
    }
}
#endif

Signals collectLocalSignals()
{
    Signals s;

#if QT_VERSION >= QT_VERSION_CHECK(6, 0, 0)
    for (const QInputDevice* dev : QInputDevice::devices()) {
        switch (dev->type()) {
        case QInputDevice::DeviceType::TouchScreen:
            s.hasTouchscreen = true;
            break;
        case QInputDevice::DeviceType::Keyboard:
            s.hasKeyboard = true;
            break;
        case QInputDevice::DeviceType::Mouse:
        case QInputDevice::DeviceType::TouchPad:
            s.hasPointer = true;
            break;
        default:
            break;
        }
    }

    // Physical size as reported by the platform, only when it looks real.
    // Virtual and headless outputs report 0 or nonsense; the payload builder
    // drops anything outside the wire ranges as well.
    if (const QScreen* screen = QGuiApplication::primaryScreen()) {
        const QSizeF mm = screen->physicalSize();
        const QSize px = screen->size();
        if (mm.width() > 0 && mm.height() > 0 && px.width() > 0 && px.height() > 0) {
            const int diagonalMm = qRound(std::hypot(mm.width(), mm.height()));
            const double nativeWidthPx = px.width() * screen->devicePixelRatio();
            const int dpi = qRound(nativeWidthPx / (mm.width() / 25.4));
            if (diagonalPlausible(diagonalMm)) {
                s.diagonalMm = diagonalMm;
                if (dpiPlausible(dpi)) {
                    s.dpi = dpi;
                }
            }
        }
    }
#endif

#ifdef Q_OS_LINUX
    s.portable = chassisIsPortable();
#endif

#ifdef Q_OS_WIN
    // Not compiled or run in the Linux development environment; checked by
    // inspection against the Win32 documentation only.
    constexpr int kSmDigitizer = 94;          // SM_DIGITIZER
    constexpr int kNidIntegratedTouch = 0x1;  // NID_INTEGRATED_TOUCH
    constexpr int kNidReady = 0x80;           // NID_READY
    const int digitizer = GetSystemMetrics(kSmDigitizer);
    s.hasTouchscreen = (digitizer & kNidIntegratedTouch) && (digitizer & kNidReady);
    s.hasPointer = GetSystemMetrics(SM_MOUSEPRESENT) != 0;
    // Windows has no cheap keyboard-presence query; a detached tablet has no
    // mouse either, so treat the two together.
    s.hasKeyboard = s.hasPointer;

    SYSTEM_POWER_STATUS power = {};
    if (GetSystemPowerStatus(&power)) {
        // 128 = no system battery
        s.portable = power.BatteryFlag != 128 && power.BatteryFlag != 255;
    }
#endif

    return s;
}

void collectOsTabletSignals(Signals& s)
{
#ifdef HAVE_POSTURE_DBUS
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (bus.isConnected()) {
        auto readBool = [&bus](const char* property) -> std::optional<bool> {
            QDBusMessage call = QDBusMessage::createMethodCall(
                QStringLiteral("org.kde.KWin"), QStringLiteral("/org/kde/KWin"),
                QStringLiteral("org.freedesktop.DBus.Properties"), QStringLiteral("Get"));
            call << QStringLiteral("org.kde.KWin.TabletModeManager") << QString::fromLatin1(property);
            const QDBusMessage reply = bus.call(call, QDBus::Block, 500);
            if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
                return std::nullopt;
            }
            const QVariant value = qvariant_cast<QDBusVariant>(reply.arguments().constFirst()).variant();
            if (value.userType() != QMetaType::Bool) {
                return std::nullopt;
            }
            return value.toBool();
        };

        s.osTabletMode = readBool("tabletMode");
        s.osTabletModeAvailable = readBool("tabletModeAvailable");
    }
#endif

#ifdef Q_OS_WIN
    // SM_CONVERTIBLESLATEMODE (0x2003): 0 = slate, non-zero = laptop. Desktops
    // and external touch monitors may report 0 as well, so only trust it on a
    // portable machine with an integrated digitizer.
    if (s.hasTouchscreen && s.portable.value_or(false)) {
        constexpr int kSmConvertibleSlateMode = 0x2003;
        s.osTabletMode = GetSystemMetrics(kSmConvertibleSlateMode) == 0;
    }
#endif

    Q_UNUSED(s);
}

} // namespace posture
