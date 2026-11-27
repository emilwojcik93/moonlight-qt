#include <QtTest>

#include "backend/postureclassifier.h"
#include "backend/displayautoconfig.h"

using namespace posture;
using std::chrono::milliseconds;

namespace {

Signals touchOnly()
{
    Signals s;
    s.hasTouchscreen = true;
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

    void touchscreenBehindDisabledPanelIsNotTouch()
    {
        // Dell 2-in-1 docked on an external display, own panel disabled; KWin
        // keeps reporting tabletMode=true from the hinge switch.
        Signals s;
        s.hasTouchscreen = true;
        s.hasKeyboard = s.hasPointer = true;
        s.portable = true;
        s.osTabletMode = true;
        s.osTabletModeAvailable = false;
        s.builtinDisplayInUse = false;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Laptop);
        QVERIFY(!r.touch);
    }

    void panelInUseOrUnknownKeepsTabletDecision()
    {
        Signals s;
        s.hasTouchscreen = true;
        s.hasKeyboard = s.hasPointer = true;
        s.portable = true;
        s.osTabletMode = true;
        s.osTabletModeAvailable = false;
        QCOMPARE(classify(s).cls, PostureClass::Tablet);
        s.builtinDisplayInUse = true;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Tablet);
        QVERIFY(r.touch);
    }

    void connectorNames()
    {
        QVERIFY(isBuiltinConnectorName("eDP-1"));
        QVERIFY(isBuiltinConnectorName("eDP1"));
        QVERIFY(isBuiltinConnectorName("LVDS-1"));
        QVERIFY(isBuiltinConnectorName("DSI-1"));
        QVERIFY(!isBuiltinConnectorName("DP-2"));
        QVERIFY(isExternalConnectorName("DP-2"));
        QVERIFY(isExternalConnectorName("HDMI-A-1"));
        QVERIFY(isExternalConnectorName("DisplayPort-0"));
        QVERIFY(!isExternalConnectorName("eDP-1"));
        QVERIFY(!isExternalConnectorName("Virtual-1"));
    }

    void displayFpsSnaps()
    {
        QCOMPARE(displayauto::snapFps(59.94), 60);
        QCOMPARE(displayauto::snapFps(60.0), 60);
        QCOMPARE(displayauto::snapFps(143.98), 144);
        QCOMPARE(displayauto::snapFps(74.97), 75);
        QCOMPARE(displayauto::snapFps(119.88), 120);
        QCOMPARE(displayauto::snapFps(165.0), 144);   // capped
        QCOMPARE(displayauto::snapFps(29.97), 30);
        QCOMPARE(displayauto::snapFps(24.0), 30);     // floor
        QCOMPARE(displayauto::snapFps(48.01), 48);    // far above 30: kept
        QCOMPARE(displayauto::snapFps(56.0), 50);     // within 10 of a standard rate
        QCOMPARE(displayauto::snapFps(98.0), 90);
    }

    void displayModeFollowsDisplay()
    {
        auto m = displayauto::chooseMode({2560, 1440, 59.94});
        QVERIFY(m.has_value());
        QCOMPARE(m->width, 2560);
        QCOMPARE(m->height, 1440);
        QCOMPARE(m->fps, 60);

        m = displayauto::chooseMode({1920, 1280, 60.0});
        QVERIFY(m.has_value());
        QCOMPARE(m->width, 1920);
        QCOMPARE(m->height, 1280);

        // Unknown refresh rate falls back to 60
        m = displayauto::chooseMode({1920, 1080, 0.0});
        QVERIFY(m.has_value());
        QCOMPARE(m->fps, 60);
    }

    void displayModeCapsAndEvens()
    {
        // Bigger than 4K: fitted inside the cap, aspect kept
        auto m = displayauto::chooseMode({5120, 2880, 60.0});
        QVERIFY(m.has_value());
        QCOMPARE(m->width, 3840);
        QCOMPARE(m->height, 2160);

        m = displayauto::chooseMode({3840, 2400, 60.0});
        QVERIFY(m.has_value());
        QVERIFY(m->width <= 3840 && m->height <= 2160);
        QCOMPARE(m->width % 2, 0);
        QCOMPARE(m->height % 2, 0);

        m = displayauto::chooseMode({1367, 769, 60.0});
        QVERIFY(m.has_value());
        QCOMPARE(m->width, 1366);
        QCOMPARE(m->height, 768);

        QVERIFY(!displayauto::chooseMode({0, 0, 60.0}).has_value());
    }

    void displayModeIsAlwaysLandscape()
    {
        // The Dell panel turned to portrait by the accelerometer
        auto m = displayauto::chooseMode({800, 1280, 60.0});
        QVERIFY(m.has_value());
        QCOMPARE(m->width, 1280);
        QCOMPARE(m->height, 800);

        m = displayauto::chooseMode({1280, 800, 60.0});
        QVERIFY(m.has_value());
        QCOMPARE(m->width, 1280);
        QCOMPARE(m->height, 800);
    }

    void displayBitrateRules()
    {
        using displayauto::StreamMode;
        const StreamMode p1080{1920, 1080, 60};
        const StreamMode p1440{2560, 1440, 60};
        const StreamMode p720{1280, 720, 60};

        // Same mode: unchanged
        QCOMPARE(displayauto::chooseBitrate(p1080, 12345, 10000, p1080, 10000), 12345);
        // Never changed from the default: default of the new mode
        QCOMPARE(displayauto::chooseBitrate(p1080, 10000, 10000, p1440, 20000), 20000);
        QCOMPARE(displayauto::chooseBitrate(p1080, 10200, 10000, p720, 5000), 5000);
        // User-set: scaled by the ratio of the defaults, 0.4x..1.0x (a ceiling)
        QCOMPARE(displayauto::chooseBitrate(p1080, 20000, 10000, p1440, 20000), 20000);   // 2x -> 1.0x
        QCOMPARE(displayauto::chooseBitrate(p1440, 25000, 20000, p1080, 10000), 12500);   // 0.5x
        QCOMPARE(displayauto::chooseBitrate(p1080, 20000, 10000, p720, 5000), 10000);     // 0.5x
        QCOMPARE(displayauto::chooseBitrate(p1080, 20000, 10000, p720, 1000), 8000);      // floor 0.4x
    }

    void displayGateDebouncesAndCools()
    {
        using displayauto::StreamMode;
        using Clock = displayauto::AdaptGate::Clock;
        const StreamMode a{1920, 1080, 60};
        const StreamMode b{2560, 1440, 60};
        const StreamMode c{2560, 1440, 120};
        const Clock::time_point t0 = Clock::now();
        auto at = [&](int ms) { return t0 + milliseconds(ms); };

        displayauto::AdaptGate gate(milliseconds(3000), milliseconds(20000));
        QVERIFY(!gate.update(a, a, at(0)));              // nothing wanted
        QVERIFY(!gate.update(b, a, at(1000)));           // difference seen
        QVERIFY(!gate.update(b, a, at(3000)));           // 2 s: still debouncing
        QVERIFY(gate.update(b, a, at(4000)));            // 3 s: restart once
        QVERIFY(!gate.update(b, a, at(4500)));           // pending reset, new debounce

        // The wanted mode keeps changing: the debounce restarts each time
        QVERIFY(!gate.update(c, a, at(5000)));
        QVERIFY(!gate.update(b, a, at(7000)));
        QVERIFY(!gate.update(c, a, at(9000)));

        // Stable again but inside the 20 s cooldown of the restart at 4 s
        QVERIFY(!gate.update(c, a, at(12500)));
        QVERIFY(!gate.update(c, a, at(23000)));          // 19 s after the restart
        QVERIFY(gate.update(c, a, at(24500)));           // cooldown over
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

    // Dell 5290: tabletMode=true, tabletModeAvailable=false while the keyboard
    // is detached (measured on the device): believe tabletMode, medium confidence,
    // even though the internal keyboard/touchpad nodes stay registered.
    void kwinQuirkTabletModeTrueIsTabletEvenWithInputNodes()
    {
        Signals s = touchLaptop();
        s.osTabletMode = true;
        s.osTabletModeAvailable = false;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Tablet);
        QCOMPARE(r.confidence, Confidence::Medium);
        QVERIFY(r.touch);
    }

    // tabletMode=false with available=false is 'unknown': use input devices
    void kwinQuirkTabletModeFalseFallsBackToDevices()
    {
        Signals s = touchLaptop();
        s.osTabletMode = false;
        s.osTabletModeAvailable = false;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Laptop);
        QVERIFY(r.touch);
    }

    void kwinQuirkWithKeyboardDetachedIsTablet()
    {
        Signals s = touchOnly();
        s.portable = true;
        s.osTabletMode = true;
        s.osTabletModeAvailable = false;
        Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Tablet);
        QCOMPARE(r.confidence, Confidence::Medium);
    }

    // Contract v2: no signal may depend on size, DPI or aspect. A touch-only
    // device is a tablet whatever it is; the classifier has no size input.
    void touchOnlyIsTabletWithoutSizeInput()
    {
        QCOMPARE(classify(touchOnly()).cls, PostureClass::Tablet);
        QCOMPARE(classify(touchOnly()).confidence, Confidence::Medium);
        Signals s = touchOnly();
        s.osTabletMode = true;
        s.osTabletModeAvailable = true;
        QCOMPARE(classify(s).cls, PostureClass::Tablet);
    }

    // Only tablet is ever produced; phone and handheld are parse-only here
    void gamepadInTabletPostureIsHandheld()
    {
        Signals s = touchLaptop();
        s.osTabletMode = true;
        s.osTabletModeAvailable = true;
        s.hasGamepad = true;
        QCOMPARE(classify(s).cls, PostureClass::Handheld);

        // Keyboard folded out: the controller does not change desktop mode
        s.osTabletMode = false;
        QCOMPARE(classify(s).cls, PostureClass::Laptop);

        // No OS signal, nothing but touch and a controller
        Signals bare = touchOnly();
        bare.hasGamepad = true;
        QCOMPARE(classify(bare).cls, PostureClass::Handheld);

        // A controller on a machine without a touchscreen changes nothing
        Signals desktop;
        desktop.hasKeyboard = true;
        desktop.hasPointer = true;
        desktop.hasGamepad = true;
        QCOMPARE(classify(desktop).cls, PostureClass::Desktop);
    }

    void handheldDeviceFormIsHandheld()
    {
        // ROG Ally style: touch, battery, a mouse device, OEM says handheld
        Signals s = touchLaptop();
        s.handheldForm = true;
        const Result r = classify(s);
        QCOMPARE(r.cls, PostureClass::Handheld);
        QCOMPARE(r.confidence, Confidence::High);
        QVERIFY(r.touch);

        // Without a touchscreen the form alone is not enough
        Signals noTouch;
        noTouch.handheldForm = true;
        QCOMPARE(classify(noTouch).cls, PostureClass::Desktop);
    }

    void overrideAlwaysHandheldAndAlwaysDesktop()
    {
        const Result handheld = resolve(touchLaptop(), Mode::AlwaysHandheld);
        QCOMPARE(handheld.cls, PostureClass::Handheld);
        QVERIFY(handheld.touch);

        Signals tablet = touchOnly();
        const Result desktop = resolve(tablet, Mode::AlwaysDesktop);
        QCOMPARE(desktop.cls, PostureClass::Laptop);
        QVERIFY(desktop.touch);
    }

    void hostModeMapping()
    {
        QCOMPARE(hostMode(PostureClass::Desktop), HostMode::Desktop);
        QCOMPARE(hostMode(PostureClass::Laptop), HostMode::Desktop);
        QCOMPARE(hostMode(PostureClass::Tablet), HostMode::Tablet);
        QCOMPARE(hostMode(PostureClass::Phone), HostMode::Tablet);
        QCOMPARE(hostMode(PostureClass::Handheld), HostMode::Handheld);
    }

    void gateSendsWhenAControllerMakesItAHandheld()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        Payload tablet{true, PostureClass::Tablet, true};
        Payload handheld{true, PostureClass::Handheld, true};
        UpdateGate gate(tablet, milliseconds(3000));
        QVERIFY(!gate.observe(handheld, t0));
        const auto sent = gate.observe(handheld, t0 + std::chrono::seconds(4));
        QVERIFY(sent.has_value());
        QCOMPARE(sent->cls, PostureClass::Handheld);
    }

    void neverProducesPhoneOrHandheldWithoutGamepadSignals()
    {
        for (int bits = 0; bits < 64; ++bits) {
            Signals s;
            s.hasTouchscreen = bits & 1;
            s.hasKeyboard = bits & 2;
            s.hasPointer = bits & 4;
            if (bits & 8) s.portable = true;
            if (bits & 16) s.osTabletMode = true;
            if (bits & 32) s.osTabletModeAvailable = false;
            const PostureClass c = classify(s).cls;
            QVERIFY(c != PostureClass::Phone && c != PostureClass::Handheld);
        }
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
        Signals s = touchOnly();
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
        // No size or DPI hints on the wire, whatever the screen is
        Signals s = touchOnly();
        s.osTabletMode = true;
        s.osTabletModeAvailable = true;
        QCOMPARE(QString::fromStdString(buildQuery(makePayload(s, Mode::Auto, false))),
                 QString("clientPosture=tablet&clientTouch=1"));
        QVERIFY(!QString::fromStdString(buildQuery(makePayload(s, Mode::Auto, true))).contains("Diagonal"));
        QVERIFY(!QString::fromStdString(buildQuery(makePayload(s, Mode::Auto, true))).contains("Dpi"));

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
        Payload tablet{true, PostureClass::Tablet, true};
        Payload phone{true, PostureClass::Phone, true};
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
        Payload desktop{true, PostureClass::Desktop, false};
        QVERIFY(!gate.observe(desktop, t0));
        Payload laptop{true, PostureClass::Laptop, false};
        QVERIFY(!gate.observe(laptop, t0 + std::chrono::seconds(10)));
    }

    void gateDebouncesAndSendsOnceOnBoundary()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        Payload laptop{true, PostureClass::Laptop, true};
        Payload tablet{true, PostureClass::Tablet, true};
        UpdateGate gate(laptop, milliseconds(3000));

        QVERIFY(!gate.observe(tablet, t0));
        QVERIFY(!gate.observe(tablet, t0 + milliseconds(2900)));
        auto sent = gate.observe(tablet, t0 + milliseconds(3000));
        QVERIFY(sent.has_value());
        QCOMPARE(sent->cls, PostureClass::Tablet);
        // Now sent: staying tablet sends nothing more
        QVERIFY(!gate.observe(tablet, t0 + milliseconds(9000)));
        // And flipping back is a new change that needs its own debounce
        QVERIFY(!gate.observe(laptop, t0 + milliseconds(10000)));
        QVERIFY(gate.observe(laptop, t0 + milliseconds(13000)).has_value());
    }

    void gateFlappingSendsOnlyFinalState()
    {
        const auto t0 = UpdateGate::Clock::time_point{} + std::chrono::seconds(100);
        Payload laptop{true, PostureClass::Laptop, true};
        Payload tablet{true, PostureClass::Tablet, true};
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
        Payload noTouch{true, PostureClass::Laptop, false};
        Payload touch{true, PostureClass::Laptop, true};
        UpdateGate gate(noTouch, milliseconds(3000));
        QVERIFY(!gate.observe(touch, t0));
        QVERIFY(gate.observe(touch, t0 + milliseconds(3000)).has_value());
    }

    // --- RestartGate -----------------------------------------------------

    void restartGateNeedsAcceptedBoundaryCrossing()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        Payload laptop{true, PostureClass::Laptop, true};
        Payload tablet{true, PostureClass::Tablet, true};
        RestartGate gate(true, laptop, t0);
        const auto later = t0 + std::chrono::seconds(30);
        QVERIFY(!gate.due(later));          // nothing accepted yet
        gate.accepted(tablet);
        QVERIFY(gate.due(later));
    }

    void restartGateIgnoresTouchToTouchAndTouchnessOnly()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        const auto later = t0 + std::chrono::seconds(30);
        Payload tablet{true, PostureClass::Tablet, true};
        Payload phone{true, PostureClass::Phone, true};
        RestartGate touch(true, tablet, t0);
        touch.accepted(phone);
        QVERIFY(!touch.due(later));

        // laptop with touch <-> laptop without: the host sees no size boundary
        Payload laptopNoTouch{true, PostureClass::Laptop, false};
        Payload laptopTouch{true, PostureClass::Laptop, true};
        RestartGate lap(true, laptopNoTouch, t0);
        lap.accepted(laptopTouch);
        QVERIFY(!lap.due(later));
    }

    void restartGateFollowsTheHostAnswer()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        const auto later = t0 + std::chrono::seconds(30);
        Payload laptop{true, PostureClass::Laptop, true};
        Payload tablet{true, PostureClass::Tablet, true};

        // Keyboard flip, host keeps its display: never restart
        RestartGate keep(true, laptop, t0);
        keep.accepted(tablet, false);
        QVERIFY(!keep.due(later));

        // Host says the display no longer fits: restart, even touch to touch
        RestartGate change(true, tablet, t0);
        change.accepted(Payload{true, PostureClass::Phone, true}, true);
        QVERIFY(change.due(later));

        // The host answer of the latest update wins
        RestartGate back(true, laptop, t0);
        back.accepted(tablet, true);
        back.accepted(laptop, false);
        QVERIFY(!back.due(later));
    }

    void parseDisplayChangeReadsTheRootAttribute()
    {
        QCOMPARE(parseDisplayChange("<?xml version=\"1.0\"?>\n<root display_change=\"0\" status_code=\"200\"/>"), std::optional<bool>(false));
        QCOMPARE(parseDisplayChange("<root status_code=\"200\" display_change=\"1\"/>"), std::optional<bool>(true));
        QVERIFY(!parseDisplayChange("<root status_code=\"200\"/>"));
        QVERIFY(!parseDisplayChange("<root display_change=\"x\"/>"));
        QVERIFY(!parseDisplayChange("<root status_code=\"200\"><a display_change=\"1\"/></root>"));
        QVERIFY(!parseDisplayChange(""));
    }

    void restartGateOmittedLaunchPayloadIsDesktop()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        RestartGate gate(true, Payload{}, t0);
        gate.accepted(Payload{true, PostureClass::Tablet, true});
        QVERIFY(gate.due(t0 + std::chrono::seconds(10)));
    }

    void restartGateSettingOffNeverRestarts()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        RestartGate gate(false, Payload{true, PostureClass::Laptop, false}, t0);
        gate.accepted(Payload{true, PostureClass::Tablet, true});
        QVERIFY(!gate.due(t0 + std::chrono::hours(1)));
    }

    void restartGateNotWhileConnecting()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        RestartGate gate(true, Payload{true, PostureClass::Laptop, false}, t0);
        gate.accepted(Payload{true, PostureClass::Tablet, true});
        QVERIFY(!gate.due(t0));
        QVERIFY(!gate.due(t0 + RestartGate::kDefaultArmDelay - milliseconds(1)));
        QVERIFY(gate.due(t0 + RestartGate::kDefaultArmDelay));
    }

    void restartGateCooldownAcrossSessions()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        Payload laptop{true, PostureClass::Laptop, false};
        Payload tablet{true, PostureClass::Tablet, true};
        // A restart happened at t0; the next session starts 8 s later
        const auto start = t0 + std::chrono::seconds(8);
        RestartGate gate(true, tablet, start, t0);
        gate.accepted(laptop);  // flipped straight back
        QVERIFY(!gate.due(start + std::chrono::seconds(10)));
        QVERIFY(!gate.due(t0 + milliseconds(59999)));
        QVERIFY(gate.due(t0 + milliseconds(60000)));  // deferred, not lost
    }

    // Baseline reset: the new session starts in the posture the user is in, so
    // the restart cannot immediately trigger another one (no loop).
    void restartGateBaselineResetPreventsLoop()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        Payload laptop{true, PostureClass::Laptop, false};
        Payload tablet{true, PostureClass::Tablet, true};
        RestartGate first(true, laptop, t0);
        first.accepted(tablet);
        const auto restartAt = t0 + std::chrono::seconds(20);
        QVERIFY(first.due(restartAt));

        // The restarted session launches as tablet; its gate is fresh
        RestartGate second(true, tablet, restartAt + std::chrono::seconds(2), restartAt);
        for (int i = 0; i < 200; ++i)
            QVERIFY(!second.due(restartAt + std::chrono::seconds(2 + i)));
        // Same posture re-reported (host accepted again): still nothing
        second.accepted(tablet);
        QVERIFY(!second.due(restartAt + std::chrono::minutes(10)));
    }

    // Flap during the cooldown: laptop -> tablet (restart) -> laptop -> tablet.
    // Only the state at cooldown end matters.
    void restartGateFlapDuringCooldown()
    {
        const auto t0 = RestartGate::Clock::time_point{} + std::chrono::seconds(1000);
        Payload laptop{true, PostureClass::Laptop, false};
        Payload tablet{true, PostureClass::Tablet, true};
        const auto restartAt = t0;
        RestartGate gate(true, tablet, restartAt + std::chrono::seconds(2), restartAt);

        gate.accepted(laptop);
        QVERIFY(!gate.due(restartAt + std::chrono::seconds(20)));   // cooldown
        gate.accepted(tablet);                                     // flapped back
        QVERIFY(!gate.due(restartAt + std::chrono::seconds(61)));  // baseline again

        gate.accepted(laptop);
        QVERIFY(gate.due(restartAt + std::chrono::seconds(61)));   // genuinely differs
    }
};

QTEST_APPLESS_MAIN(PostureTest)
#include "tst_posture.moc"
