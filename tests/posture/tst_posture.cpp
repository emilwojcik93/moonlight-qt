#include <QtTest>

#include "backend/postureclassifier.h"

using namespace posture;
using std::chrono::milliseconds;

namespace {

Signals touchOnly(int diagonalMm = 0)
{
    Signals s;
    s.hasTouchscreen = true;
    s.diagonalMm = diagonalMm;
    return s;
}

Signals touchLaptop()
{
    Signals s;
    s.hasTouchscreen = true;
    s.hasKeyboard = true;
    s.hasPointer = true;
    s.portable = true;
    return s;
}

} // namespace

class PostureTest : public QObject
{
    Q_OBJECT

private slots:
    void classNames()
    {
        PostureClass c;
        QVERIFY(parseClassName("handheld", c));
        QCOMPARE(c, PostureClass::Handheld);
        QVERIFY(!parseClassName("Tablet", c));  // lowercase only
        QVERIFY(!parseClassName("", c));
        QCOMPARE(QString(className(PostureClass::Phone)), QString("phone"));
    }

    void noTouchIsDesktop()
    {
        Signals s;
        s.hasKeyboard = s.hasPointer = true;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Desktop);
        QVERIFY(!r.touch);
        QCOMPARE(r.confidence, Confidence::High);
    }

    void noTouchPortableIsLaptop()
    {
        Signals s;
        s.hasKeyboard = s.hasPointer = true;
        s.portable = true;
        QCOMPARE(classify(s).cls, PostureClass::Laptop);
    }

    void noTouchIgnoresTabletMode()
    {
        Signals s;
        s.osTabletMode = true;
        s.osTabletModeAvailable = true;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Desktop);
        QCOMPARE(r.confidence, Confidence::Low);
    }

    void trustedTabletMode()
    {
        Signals s = touchLaptop();
        s.osTabletMode = true;
        s.osTabletModeAvailable = true;
        s.diagonalMm = 305;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Tablet);
        QCOMPARE(r.confidence, Confidence::High);
        QVERIFY(r.touch);
    }

    void trustedLaptopMode()
    {
        Signals s = touchLaptop();
        s.osTabletMode = false;
        s.osTabletModeAvailable = true;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Laptop);
        QCOMPARE(r.confidence, Confidence::High);
    }

    // Dell 5290: tabletMode=true, tabletModeAvailable=false
    void kwinQuirkWithKeyboardAttachedIsLowConfidenceLaptop()
    {
        Signals s = touchLaptop();
        s.osTabletMode = true;
        s.osTabletModeAvailable = false;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Laptop);
        QCOMPARE(r.confidence, Confidence::Low);
        QVERIFY(r.touch);
    }

    void kwinQuirkWithKeyboardDetachedIsTablet()
    {
        Signals s = touchOnly(305);
        s.portable = true;
        s.osTabletMode = true;
        s.osTabletModeAvailable = false;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Tablet);
        QCOMPARE(r.confidence, Confidence::Medium);
    }

    void touchOnlyFallbackBySize()
    {
        QCOMPARE(classify(touchOnly()).cls, PostureClass::Tablet);
        QCOMPARE(classify(touchOnly(150)).cls, PostureClass::Phone);
        QCOMPARE(classify(touchOnly(kPhoneMaxDiagonalMm)).cls, PostureClass::Phone);
        QCOMPARE(classify(touchOnly(kPhoneMaxDiagonalMm + 1)).cls, PostureClass::Handheld);
        QCOMPARE(classify(touchOnly(kHandheldMaxDiagonalMm)).cls, PostureClass::Handheld);
        QCOMPARE(classify(touchOnly(kHandheldMaxDiagonalMm + 1)).cls, PostureClass::Tablet);
        QCOMPARE(classify(touchOnly(9999)).cls, PostureClass::Tablet);  // implausible size
    }

    void touchMonitorIsDesktopWhenNotPortable()
    {
        Signals s = touchLaptop();
        s.portable = false;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Desktop);
        QVERIFY(r.touch);
    }

    void windowsSlateMode()
    {
        // SM_CONVERTIBLESLATEMODE == 0 with an integrated digitizer
        Signals s = touchLaptop();
        s.osTabletMode = true;
        QCOMPARE(classify(s).cls, PostureClass::Tablet);
        s.osTabletMode = false;
        QCOMPARE(classify(s).cls, PostureClass::Laptop);
    }

    void overrideNeverSendsNothing()
    {
        Signals s = touchOnly(305);
        QVERIFY(!makePayload(s, Mode::Never, false).valid);
        QVERIFY(!makePayload(s, Mode::Never, true).valid);
        QVERIFY(buildQuery(makePayload(s, Mode::Never, false)).empty());
    }

    void overrideAlwaysTabletWinsOverDetection()
    {
        Signals s;  // plain desktop
        s.hasKeyboard = s.hasPointer = true;
        Payload p = makePayload(s, Mode::AlwaysTablet, false);
        QVERIFY(p.valid);
        QCOMPARE(p.cls, PostureClass::Tablet);
        QVERIFY(p.touch);
        QCOMPARE(QString::fromStdString(buildQuery(p)), QString("clientPosture=tablet&clientTouch=1"));
    }

    void desktopWithoutTouchOmitsParamsOnLaunch()
    {
        Signals s;
        s.hasKeyboard = s.hasPointer = true;
        QVERIFY(!makePayload(s, Mode::Auto, false).valid);
        // A runtime update must be explicit so the host can leave touch posture
        Payload u = makePayload(s, Mode::Auto, true);
        QVERIFY(u.valid);
        QCOMPARE(QString::fromStdString(buildQuery(u)), QString("clientPosture=desktop&clientTouch=0"));
    }

    void queryBuilding()
    {
        Signals s = touchOnly();
        s.osTabletMode = true;
        s.osTabletModeAvailable = true;
        s.diagonalMm = 305;
        s.dpi = 160;
        QCOMPARE(QString::fromStdString(buildQuery(makePayload(s, Mode::Auto, false))),
                 QString("clientPosture=tablet&clientTouch=1&clientDiagonalMm=305&clientDpi=160"));

        // Out-of-range hints are dropped, not clamped
        s.diagonalMm = 49;
        s.dpi = 801;
        QCOMPARE(QString::fromStdString(buildQuery(makePayload(s, Mode::Auto, false))),
                 QString("clientPosture=tablet&clientTouch=1"));
        s.diagonalMm = 800;
        s.dpi = 72;
        QCOMPARE(QString::fromStdString(buildQuery(makePayload(s, Mode::Auto, false))),
                 QString("clientPosture=tablet&clientTouch=1&clientDiagonalMm=800&clientDpi=72"));

        // Laptop is sent (host ignores it); touch=1 only when a touchscreen exists
        Signals l;
        l.hasKeyboard = l.hasPointer = true;
        l.portable = true;
        QCOMPARE(QString::fromStdString(buildQuery(makePayload(l, Mode::Auto, false))),
                 QString("clientPosture=laptop&clientTouch=0"));

        QVERIFY(buildQuery(Payload{}).empty());
    }

    void gateIgnoresUnchangedAndSameBoundaryChanges()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        Payload tablet{true, PostureClass::Tablet, true, 0, 0};
        Payload phone{true, PostureClass::Phone, true, 0, 0};
        UpdateGate gate(tablet, milliseconds(3000));
        QVERIFY(!gate.observe(tablet, t0));
        // Touch class to touch class never crosses the boundary
        for (int i = 0; i < 10; ++i)
            QVERIFY(!gate.observe(phone, t0 + std::chrono::seconds(i * 2)));
    }

    void gateOmittedLaunchMeansDesktop()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        UpdateGate gate(Payload{}, milliseconds(3000));
        Payload desktop{true, PostureClass::Desktop, false, 0, 0};
        QVERIFY(!gate.observe(desktop, t0));
        Payload laptop{true, PostureClass::Laptop, false, 0, 0};
        QVERIFY(!gate.observe(laptop, t0 + std::chrono::seconds(10)));
    }

    void gateDebouncesAndSendsOnceOnBoundary()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        Payload laptop{true, PostureClass::Laptop, true, 0, 0};
        Payload tablet{true, PostureClass::Tablet, true, 305, 160};
        UpdateGate gate(laptop, milliseconds(3000));

        QVERIFY(!gate.observe(tablet, t0));
        QVERIFY(!gate.observe(tablet, t0 + milliseconds(2900)));
        auto sent = gate.observe(tablet, t0 + milliseconds(3000));
        QVERIFY(sent.has_value());
        QCOMPARE(sent->cls, PostureClass::Tablet);
        QCOMPARE(sent->diagonalMm, 305);
        // Now sent: staying tablet sends nothing more
        QVERIFY(!gate.observe(tablet, t0 + milliseconds(9000)));
        // And flipping back is a new change that needs its own debounce
        QVERIFY(!gate.observe(laptop, t0 + milliseconds(10000)));
        QVERIFY(gate.observe(laptop, t0 + milliseconds(13000)).has_value());
    }

    void gateFlappingSendsOnlyFinalState()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        Payload laptop{true, PostureClass::Laptop, true, 0, 0};
        Payload tablet{true, PostureClass::Tablet, true, 0, 0};
        UpdateGate gate(laptop, milliseconds(3000));

        // Flip back and forth inside the window: nothing is sent, even once
        // the total time exceeds the debounce interval.
        QVERIFY(!gate.observe(tablet, t0));
        QVERIFY(!gate.observe(laptop, t0 + milliseconds(1000)));
        QVERIFY(!gate.observe(tablet, t0 + milliseconds(2000)));
        QVERIFY(!gate.observe(laptop, t0 + milliseconds(3000)));
        QVERIFY(!gate.observe(tablet, t0 + milliseconds(4000)));
        QVERIFY(!gate.observe(tablet, t0 + milliseconds(6999)));
        auto sent = gate.observe(tablet, t0 + milliseconds(7000));
        QVERIFY(sent.has_value());
        QCOMPARE(sent->cls, PostureClass::Tablet);
    }

    void gateTouchnessChangeCounts()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        Payload noTouch{true, PostureClass::Laptop, false, 0, 0};
        Payload touch{true, PostureClass::Laptop, true, 0, 0};
        UpdateGate gate(noTouch, milliseconds(3000));
        QVERIFY(!gate.observe(touch, t0));
        QVERIFY(gate.observe(touch, t0 + milliseconds(3000)).has_value());
    }
};

QTEST_APPLESS_MAIN(PostureTest)
#include "tst_posture.moc"
