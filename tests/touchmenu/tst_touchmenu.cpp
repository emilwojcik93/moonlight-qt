#include <QtTest>

#include <cmath>

#include "streaming/input/touchmenu.h"

using namespace touchmenu;

namespace {

// Three fingers well away from the menu, spread out
void threeDown(TouchMenu& m, uint32_t t)
{
    QCOMPARE(m.fingerDown(1, 0.50f, 0.20f, t).type, EventType::None);
    QCOMPARE(m.fingerDown(2, 0.60f, 0.20f, t).type, EventType::None);
    QCOMPARE(m.fingerDown(3, 0.70f, 0.20f, t).type, EventType::None);
}

// Opens the menu with three fingers at t = 0 .. 800 and lifts them
void openMenu(TouchMenu& m, uint32_t& now)
{
    threeDown(m, 0);
    QCOMPARE(m.tick(HoldMs).type, EventType::Open);
    now = HoldMs;
    QVERIFY(m.isOpen());
}

void liftHoldFingers(TouchMenu& m, uint32_t t)
{
    QVERIFY(m.fingerUp(1, 0.50f, 0.20f, t).swallow);
    QVERIFY(m.fingerUp(2, 0.60f, 0.20f, t).swallow);
    QVERIFY(m.fingerUp(3, 0.70f, 0.20f, t).swallow);
}

// Center of an item in normalized window coordinates
void itemCenter(int outW, int outH, int item, float& x, float& y)
{
    Layout l = computeLayout(outW, outH);
    const Rect& r = l.items[item];
    x = (r.x + r.w / 2.0f) / outW;
    y = (outH - l.surfaceHeight + r.y + r.h / 2.0f) / outH;
}

} // namespace

class TouchMenuTest : public QObject
{
    Q_OBJECT

private:
    TouchMenu m;

private slots:
    void init()
    {
        m = TouchMenu();
        m.setOutputSize(1280, 720);
    }

    void threeFingersOpenAfterHold()
    {
        threeDown(m, 1000);
        QVERIFY(m.needsTick());
        QCOMPARE(m.tick(1000).type, EventType::None);
        QCOMPARE(m.tick(1000 + HoldMs - 1).type, EventType::None);
        QVERIFY(!m.isOpen());
        Event e = m.tick(1000 + HoldMs);
        QCOMPARE(e.type, EventType::Open);
        QVERIFY(e.swallow);
        QVERIFY(m.isOpen());
    }

    void eventsReachHostUntilOpen()
    {
        QVERIFY(!m.fingerDown(1, 0.5f, 0.2f, 0).swallow);
        QVERIFY(!m.fingerDown(2, 0.6f, 0.2f, 0).swallow);
        QVERIFY(!m.fingerDown(3, 0.7f, 0.2f, 0).swallow);
        QVERIFY(!m.fingerMove(1, 0.501f, 0.2f, 100).swallow);
    }

    void twoFingersNeverOpen()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerDown(2, 0.6f, 0.2f, 0);
        QCOMPARE(m.tick(HoldMs).type, EventType::None);
        QCOMPARE(m.tick(60000).type, EventType::None);
        QVERIFY(!m.isOpen());
    }

    void movementBeyondThresholdCancels()
    {
        threeDown(m, 0);
        // 3 % of 720 px = 21.6 px: 40 px is too far
        m.fingerMove(2, 0.60f, 0.20f + 40.0f / 720.0f, 100);
        QCOMPARE(m.tick(HoldMs).type, EventType::None);
        QVERIFY(!m.isOpen());
    }

    void smallMovementDoesNotCancel()
    {
        threeDown(m, 0);
        m.fingerMove(2, 0.60f, 0.20f + 10.0f / 720.0f, 100);
        QCOMPARE(m.tick(HoldMs).type, EventType::Open);
    }

    void thresholdUsesShorterSide()
    {
        threeDown(m, 0);
        // 25 px sideways: below 3 % of the width (38 px) but above 3 % of the shorter side (21.6 px)
        m.fingerMove(1, 0.50f + 25.0f / 1280.0f, 0.20f, 100);
        QCOMPARE(m.tick(HoldMs).type, EventType::None);
    }

    void cancelledByMovementDoesNotRearmWhileThreeDown()
    {
        threeDown(m, 0);
        m.fingerMove(2, 0.60f, 0.40f, 100);
        // Finger comes back and holds still: still cancelled
        m.fingerMove(2, 0.60f, 0.20f, 200);
        QCOMPARE(m.tick(5000).type, EventType::None);
        // Fingers lift below three, then a new hold works
        m.fingerUp(3, 0.70f, 0.20f, 6000);
        m.fingerDown(3, 0.70f, 0.20f, 6100);
        QCOMPARE(m.tick(6100 + HoldMs).type, EventType::Open);
    }

    void fingerLiftedEarlyCancels()
    {
        threeDown(m, 0);
        m.fingerUp(3, 0.70f, 0.20f, 400);
        QCOMPARE(m.tick(HoldMs).type, EventType::None);
        // The finger lands again: the hold restarts from that moment
        m.fingerDown(3, 0.70f, 0.20f, 1000);
        QCOMPARE(m.tick(1000 + HoldMs - 1).type, EventType::None);
        QCOMPARE(m.tick(1000 + HoldMs).type, EventType::Open);
    }

    void fourthFingerDoesNotRestartHold()
    {
        threeDown(m, 0);
        m.fingerDown(4, 0.80f, 0.20f, 500);
        // Timed from the third finger, not from the fourth
        QCOMPARE(m.tick(HoldMs).type, EventType::Open);
    }

    void fourthFingerMovementCancels()
    {
        threeDown(m, 0);
        m.fingerDown(4, 0.80f, 0.20f, 500);
        m.fingerMove(4, 0.80f, 0.50f, 600);
        QCOMPARE(m.tick(HoldMs).type, EventType::None);
    }

    void fourthFingerLeavingKeepsHold()
    {
        threeDown(m, 0);
        m.fingerDown(4, 0.80f, 0.20f, 500);
        m.fingerUp(4, 0.80f, 0.20f, 600);
        QCOMPARE(m.tick(HoldMs).type, EventType::Open);
    }

    void thirdFingerAfterScrollingFingersDoesNotArm()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerDown(2, 0.6f, 0.2f, 0);
        m.fingerMove(1, 0.5f, 0.5f, 100);
        m.fingerDown(3, 0.7f, 0.2f, 200);
        QCOMPARE(m.tick(2000).type, EventType::None);
    }

    void openedMenuSwallowsEverything()
    {
        uint32_t now;
        openMenu(m, now);
        // Fingers that were down stay swallowed, also their lift and any move
        QVERIFY(m.fingerMove(1, 0.51f, 0.2f, now + 10).swallow);
        liftHoldFingers(m, now + 20);
        // New touches too
        QVERIFY(m.fingerDown(5, 0.1f, 0.1f, now + 30).swallow);
        QVERIFY(m.fingerMove(5, 0.1f, 0.2f, now + 40).swallow);
    }

    void holdFingersDoNotActivateOnLift()
    {
        // Fingers hold right above the "Disconnect" item and lift there
        float x, y;
        itemCenter(1280, 720, ItemDisconnect, x, y);
        m.fingerDown(1, x, y, 0);
        m.fingerDown(2, x + 0.02f, y, 0);
        m.fingerDown(3, x - 0.02f, y, 0);
        QCOMPARE(m.tick(HoldMs).type, EventType::Open);
        QCOMPARE(m.fingerUp(1, x, y, 900).type, EventType::None);
        QCOMPARE(m.fingerUp(2, x + 0.02f, y, 900).type, EventType::None);
        QCOMPARE(m.fingerUp(3, x - 0.02f, y, 900).type, EventType::None);
        QVERIFY(m.isOpen());
    }

    void activationNeedsDownAndUpOnSameItem()
    {
        uint32_t now;
        openMenu(m, now);
        liftHoldFingers(m, now);

        float dx, dy, sx, sy;
        itemCenter(1280, 720, ItemDisconnect, dx, dy);
        itemCenter(1280, 720, ItemToggleStats, sx, sy);

        // Down on one item, up on another: nothing
        m.fingerDown(7, dx, dy, now + 100);
        QCOMPARE(m.highlightedItem(), (int)ItemDisconnect);
        m.fingerMove(7, sx, sy, now + 150);
        QCOMPARE(m.highlightedItem(), -1);
        Event e = m.fingerUp(7, sx, sy, now + 200);
        QCOMPARE(e.type, EventType::None);
        QVERIFY(m.isOpen());

        // Down and up on the same item
        m.fingerDown(8, sx, sy, now + 300);
        QCOMPARE(m.highlightedItem(), (int)ItemToggleStats);
        e = m.fingerUp(8, sx, sy, now + 350);
        QCOMPARE(e.type, EventType::Activate);
        QCOMPARE(e.item, (int)ItemToggleStats);
        QVERIFY(e.swallow);
        QVERIFY(!m.isOpen());
        QVERIFY(!m.needsTick());
    }

    void disconnectItemActivates()
    {
        uint32_t now;
        openMenu(m, now);
        liftHoldFingers(m, now);
        float x, y;
        itemCenter(1280, 720, ItemDisconnect, x, y);
        m.fingerDown(7, x, y, now + 100);
        Event e = m.fingerUp(7, x, y, now + 150);
        QCOMPARE(e.type, EventType::Activate);
        QCOMPARE(e.item, (int)ItemDisconnect);
    }

    void closeItemCloses()
    {
        uint32_t now;
        openMenu(m, now);
        liftHoldFingers(m, now);
        float x, y;
        itemCenter(1280, 720, ItemCloseMenu, x, y);
        m.fingerDown(7, x, y, now + 100);
        QCOMPARE(m.fingerUp(7, x, y, now + 150).type, EventType::Close);
        QVERIFY(!m.isOpen());
        // Normal input resumes
        QVERIFY(!m.fingerDown(9, 0.5f, 0.2f, now + 300).swallow);
    }

    void tapOutsideCloses()
    {
        uint32_t now;
        openMenu(m, now);
        liftHoldFingers(m, now);
        m.fingerDown(7, 0.9f, 0.1f, now + 100);
        Event e = m.fingerUp(7, 0.9f, 0.1f, now + 150);
        QCOMPARE(e.type, EventType::Close);
        QVERIFY(e.swallow);
        QVERIFY(!m.isOpen());
    }

    void idleTimeoutCloses()
    {
        uint32_t now;
        openMenu(m, now);
        liftHoldFingers(m, now);
        QCOMPARE(m.tick(now + IdleMs - 1).type, EventType::None);
        QVERIFY(m.isOpen());
        QCOMPARE(m.tick(now + IdleMs).type, EventType::Close);
        QVERIFY(!m.isOpen());
        QVERIFY(!m.needsTick());
    }

    void touchRestartsIdleTimeout()
    {
        uint32_t now;
        openMenu(m, now);
        liftHoldFingers(m, now);
        float x, y;
        itemCenter(1280, 720, ItemDisconnect, x, y);
        // A touch late in the idle period restarts it
        m.fingerDown(8, x, y, now + 9000);
        m.fingerMove(8, x, y, now + 9500);
        m.fingerUp(8, 0.9f, 0.1f, now + 9600); // Down on an item, up outside: no action
        QVERIFY(m.isOpen());
        QCOMPARE(m.tick(now + 9600 + IdleMs - 1).type, EventType::None);
        QCOMPARE(m.tick(now + 9600 + IdleMs).type, EventType::Close);
    }

    void fingersHeldThroughCloseStaySwallowed()
    {
        threeDown(m, 0);
        QCOMPARE(m.tick(HoldMs).type, EventType::Open);
        QCOMPARE(m.tick(HoldMs + IdleMs).type, EventType::Close);
        // The three fingers are still down: they do not reach the host,
        // and they do not start another hold.
        QVERIFY(m.fingerMove(1, 0.5f, 0.2f, HoldMs + IdleMs + 10).swallow);
        QCOMPARE(m.tick(HoldMs + 2 * IdleMs).type, EventType::None);
        QVERIFY(m.fingerUp(1, 0.5f, 0.2f, HoldMs + 2 * IdleMs).swallow);
        m.fingerUp(2, 0.6f, 0.2f, HoldMs + 2 * IdleMs);
        m.fingerUp(3, 0.7f, 0.2f, HoldMs + 2 * IdleMs);
        QVERIFY(!m.fingerDown(1, 0.5f, 0.2f, HoldMs + 3 * IdleMs).swallow);
    }

    void gestureWorksAgainAfterClose()
    {
        uint32_t now;
        openMenu(m, now);
        liftHoldFingers(m, now);
        m.fingerDown(7, 0.9f, 0.1f, now + 100);
        QCOMPARE(m.fingerUp(7, 0.9f, 0.1f, now + 150).type, EventType::Close);
        uint32_t t = now + 1000;
        threeDown(m, t);
        QCOMPARE(m.tick(t + HoldMs).type, EventType::Open);
    }

    void tickWrapAround()
    {
        uint32_t t = 0xFFFFFF00u;
        threeDown(m, t);
        QCOMPARE(m.tick(t + 100).type, EventType::None);
        QCOMPARE(m.tick(t + HoldMs).type, EventType::Open); // wraps past 2^32
    }

    void layoutThreeItems_data()
    {
        QTest::addColumn<int>("w");
        QTest::addColumn<int>("h");
        QTest::newRow("1920x1280") << 1920 << 1280;
        QTest::newRow("1280x720") << 1280 << 720;
        QTest::newRow("720x1280") << 720 << 1280;
        QTest::newRow("3840x2160") << 3840 << 2160;
    }

    void layoutThreeItems()
    {
        QFETCH(int, w);
        QFETCH(int, h);
        Layout l = computeLayout(w, h);
        QVERIFY(l.valid);
        QVERIFY(l.surfaceWidth > 0 && l.surfaceWidth <= w);
        QVERIFY(l.surfaceHeight > 0 && l.surfaceHeight <= h);
        QVERIFY(l.fontPixels >= 12);

        const int minHeight = (int)std::ceil(h * MinItemHeightFraction);
        for (int i = 0; i < ItemCount; i++) {
            const Rect& r = l.items[i];
            QVERIFY2(r.h >= minHeight, "item shorter than the minimum");
            QVERIFY(r.x >= 0 && r.y >= 0);
            QVERIFY(r.x + r.w <= l.surfaceWidth);
            QVERIFY(r.y + r.h <= l.surfaceHeight);
            QVERIFY(QString(itemLabel(i)).size() > 0);
            for (int j = i + 1; j < ItemCount; j++) {
                const Rect& o = l.items[j];
                bool apart = r.x + r.w <= o.x || o.x + o.w <= r.x ||
                             r.y + r.h <= o.y || o.y + o.h <= r.y;
                QVERIFY2(apart, "items overlap");
            }
        }
        // Stacked top to bottom in menu order
        QVERIFY(l.items[0].y < l.items[1].y && l.items[1].y < l.items[2].y);
    }

    void layoutHitTest()
    {
        m.setOutputSize(1920, 1280);
        for (int i = 0; i < ItemCount; i++) {
            float x, y;
            itemCenter(1920, 1280, i, x, y);
            QCOMPARE(m.hitTest(x, y), i);
        }
        // Top of the window is outside the menu
        QCOMPARE(m.hitTest(0.1f, 0.05f), -1);
        // Right of the menu
        QCOMPARE(m.hitTest(0.99f, 0.95f), -1);
    }

    void activityShowsHandle()
    {
        QVERIFY(!m.handleVisible());
        QVERIFY(!m.needsTick());
        QVERIFY(!m.fingerDown(1, 0.5f, 0.2f, 0).swallow);
        QVERIFY(m.handleVisible());
        QVERIFY(m.needsTick());
    }

    void handleHidesAfterIdle()
    {
        m.fingerDown(1, 0.5f, 0.2f, 100);
        m.fingerUp(1, 0.5f, 0.2f, 200);
        QCOMPARE(m.tick(200 + HandleHideMs - 1).type, EventType::None);
        QVERIFY(m.handleVisible());
        QCOMPARE(m.tick(200 + HandleHideMs).type, EventType::None);
        QVERIFY(!m.handleVisible());
        QVERIFY(!m.needsTick());
    }

    void activityRestartsHandleHide()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerUp(1, 0.5f, 0.2f, 5000);
        m.tick(5000 + HandleHideMs - 1);
        QVERIFY(m.handleVisible());
    }

    void tapOnVisibleHandleOpensMenu()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerUp(1, 0.5f, 0.2f, 100);
        float x = 28.0f / 1280, y = (720 - 28.0f) / 720;
        QVERIFY(m.fingerDown(9, x, y, 200).swallow);
        Event e = m.fingerUp(9, x, y, 300);
        QCOMPARE(e.type, EventType::Open);
        QVERIFY(e.swallow);
        QVERIFY(m.isOpen());
        QVERIFY(!m.handleVisible());
        // The menu works as after the hold: an outside tap closes it
        m.fingerDown(10, 0.9f, 0.1f, 400);
        QCOMPARE(m.fingerUp(10, 0.9f, 0.1f, 450).type, EventType::Close);
    }

    void handleDownInsideLiftOutsideDoesNotOpen()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerUp(1, 0.5f, 0.2f, 100);
        float x = 28.0f / 1280, y = (720 - 28.0f) / 720;
        QVERIFY(m.fingerDown(9, x, y, 200).swallow);
        QVERIFY(m.fingerMove(9, 0.5f, 0.5f, 250).swallow);
        Event e = m.fingerUp(9, 0.5f, 0.5f, 300);
        QCOMPARE(e.type, EventType::None);
        QVERIFY(e.swallow);
        QVERIFY(!m.isOpen());
    }

    void handleDragInsideHandleDoesNotOpen()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerUp(1, 0.5f, 0.2f, 100);
        // 30 px inside the 56 px handle is more than 3 % of 720
        QVERIFY(m.fingerDown(9, 5.0f / 1280, 715.0f / 720, 200).swallow);
        Event e = m.fingerUp(9, 35.0f / 1280, 715.0f / 720, 300);
        QCOMPARE(e.type, EventType::None);
        QVERIFY(e.swallow);
    }

    void cornerTouchWhileHiddenIsForwarded()
    {
        float x = 28.0f / 1280, y = (720 - 28.0f) / 720;
        QVERIFY(!m.handleVisible());
        QVERIFY(!m.fingerDown(1, x, y, 0).swallow);
        QVERIFY(m.handleVisible());
        // That tap does not open anything
        Event e = m.fingerUp(1, x, y, 100);
        QCOMPARE(e.type, EventType::None);
        QVERIFY(!e.swallow);
        QVERIFY(!m.isOpen());
    }

    void handleFingerDoesNotCountForHold()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerUp(1, 0.5f, 0.2f, 50);
        m.fingerDown(9, 28.0f / 1280, 692.0f / 720, 100); // swallowed on the handle
        m.fingerDown(2, 0.6f, 0.2f, 100);
        m.fingerDown(3, 0.7f, 0.2f, 100);
        QCOMPARE(m.gestureFingerCount(), 2);
        QCOMPARE(m.tick(100 + HoldMs).type, EventType::None);
    }

    void redownOfTrackedIdReplaces()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerDown(2, 0.6f, 0.2f, 0);
        // The compositor lost finger 1's up: the same id comes back
        m.fingerDown(1, 0.4f, 0.4f, 500);
        QCOMPARE(m.gestureFingerCount(), 2);
        QCOMPARE(m.tick(500 + HoldMs).type, EventType::None);
        // A real third finger still arms
        m.fingerDown(3, 0.7f, 0.2f, 600);
        QCOMPARE(m.gestureFingerCount(), 3);
        QCOMPARE(m.tick(600 + HoldMs).type, EventType::Open);
    }

    void lostFingersAreForgottenWhenIdle()
    {
        m.fingerDown(1, 0.5f, 0.2f, 0);
        m.fingerDown(2, 0.6f, 0.2f, 0);
        m.tick(HandleHideMs);
        QCOMPARE(m.gestureFingerCount(), 0);
        // Two stale records no longer make a phantom third finger
        m.fingerDown(3, 0.7f, 0.2f, HandleHideMs + 100);
        QCOMPARE(m.tick(HandleHideMs + 100 + HoldMs).type, EventType::None);
    }

    void fingerCancelActsLikeUpWithoutActivation()
    {
        threeDown(m, 0);
        m.fingerCancel(3, 100);
        QCOMPARE(m.gestureFingerCount(), 2);
        QCOMPARE(m.tick(HoldMs).type, EventType::None);

        // Cancel of the pressed finger in the open menu activates nothing
        uint32_t t = 1000;
        m.fingerDown(3, 0.7f, 0.2f, t);
        QCOMPARE(m.tick(t + HoldMs).type, EventType::Open);
        float x, y;
        itemCenter(1280, 720, ItemDisconnect, x, y);
        m.fingerDown(7, x, y, t + 900);
        QCOMPARE(m.fingerCancel(7, t + 950).type, EventType::None);
        QVERIFY(m.isOpen());
        QCOMPARE(m.highlightedItem(), -1);
    }

    void handleRectSizes()
    {
        Rect r = handleRect(1920, 1280);
        QCOMPARE(r.x, 0);
        QCOMPARE(r.w, 77);
        QCOMPARE(r.h, 77);
        QCOMPARE(r.y, 1280 - 77);
        r = handleRect(1280, 720);
        QCOMPARE(r.w, 56); // 6 % is 43 px, the minimum wins
        QCOMPARE(r.h, 56);
        QCOMPARE(r.y, 720 - 56);
        QCOMPARE(handleSize(1280, 0), 0);
    }

    void layoutInvalidOutput()
    {
        QVERIFY(!computeLayout(0, 720).valid);
        QVERIFY(!computeLayout(1280, 0).valid);
    }
};

QTEST_APPLESS_MAIN(TouchMenuTest)
#include "tst_touchmenu.moc"
