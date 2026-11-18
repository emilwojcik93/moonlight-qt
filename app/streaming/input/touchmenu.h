#pragma once

// Touch-only in-stream menu for the stream-posture-sync feature.
//
// Pure logic, no SDL and no Qt GUI: recognizes the "three fingers held still"
// gesture, tracks the menu while it is open and lays the menu out. Finger
// positions are normalized 0..1 window coordinates, time is passed in as
// milliseconds (any monotonic uint32 clock, wrap-around safe). The caller
// (SdlInputHandler) owns the clock and a periodic tick, sends the events to the
// host or swallows them, and draws the menu (OverlayManager).
//
// Gesture rule: the hold starts when the third finger lands. A fourth finger
// joining while the hold runs does not restart it. The hold is cancelled when
// fewer than three fingers are down or when any finger (including a joined
// one) has moved 3 % of the shorter window side or more from where it landed.
// Corner handle: the second trigger, for platforms where the compositor keeps
// a third finger from reaching the client. Any finger event shows a small
// handle at the bottom-left corner of the output; it hides after HandleHideMs
// without a finger event. A tap on the visible handle (down and up inside it,
// moved less than MoveFraction) opens the menu. A touch that starts inside the
// visible handle never reaches the host, whether or not it ends as a tap. A
// touch that starts on the corner while the handle is hidden is a normal
// touch and only makes the handle appear.
//
// Lost contacts: a down for an id that is already tracked replaces the old
// record. When the handle hides after HandleHideMs without any finger event,
// the remaining tracked fingers are forgotten (the compositor can swallow
// their up events), so they cannot count towards a later hold.
//
// Edge swipe: the trigger that works where the compositor takes three fingers.
// Two fingers that each land within the rightmost EdgeZoneFraction of the output
// width, at most EdgePairMs apart, and then both move left by at least
// EdgeSwipeFraction of the output width within EdgeSwipeWindowMs of the first
// landing, open the menu on the right side. The attempt is cancelled when
// either finger lifts, when another finger lands (or the second lands too
// late), when either finger moves right by more than MoveFraction, or on
// timeout. Until it opens the touches reach the host; on open the two fingers
// are swallowed until they lift and activate nothing. The handle tap and the
// three finger hold open the menu on the left side.
//
// After a cancel by movement the gesture cannot re-arm until fewer than three
// fingers are down again. Fingers that were down when the menu opened, or that
// landed while it was open, never take part in a later gesture or reach the
// host: they stay swallowed until they lift.

#include <cstdint>
#include <vector>

namespace touchmenu {

constexpr uint32_t HoldMs = 800;
constexpr uint32_t IdleMs = 10000;
constexpr uint32_t HandleHideMs = 6000;
constexpr float EdgeZoneFraction = 0.08f;
constexpr uint32_t EdgePairMs = 300;
constexpr float EdgeSwipeFraction = 0.10f;
constexpr uint32_t EdgeSwipeWindowMs = 1200;
constexpr int HoldFingers = 3;
constexpr float MoveFraction = 0.03f;
constexpr float MinItemHeightFraction = 0.12f;
constexpr float HandleHeightFraction = 0.06f;
constexpr int HandleMinPixels = 56;
constexpr int ItemCount = 3;

enum Item {
    ItemDisconnect = 0,
    ItemToggleStats = 1,
    ItemCloseMenu = 2,
};

// Screen side the panel opens on
enum class Side {
    Left,
    Right,
};

enum class EventType {
    None,
    Open,
    Activate,   // item = ItemDisconnect or ItemToggleStats, menu is closed
    Close,      // menu is closed (close item, tap outside, idle timeout)
};

struct Event {
    EventType type = EventType::None;
    int item = -1;
    Side side = Side::Left; // For Open: the side the panel opens on
    // True when the touch event that produced this result must not reach the host
    bool swallow = false;
};

struct Rect {
    int x = 0, y = 0, w = 0, h = 0;
};

// Menu geometry for an output of outputWidth x outputHeight pixels. The surface
// is anchored at the bottom-left corner of the output: its top-left corner is
// at (0, outputHeight - surfaceHeight), so surface x equals output x. For the
// left side the surface is just the panel. For the right side the surface is
// as wide as the output, transparent except for the panel at its right end.
// Items are relative to the surface; itemInOutput() gives output pixels.
struct Layout {
    bool valid = false;
    int surfaceWidth = 0, surfaceHeight = 0;
    int panelX = 0, panelWidth = 0;  // Panel inside the surface, full surface height
    int originY = 0;                 // Output y of the surface's top edge
    int border = 1;     // item and frame border thickness
    int fontPixels = 12;
    Rect items[ItemCount];

    Rect itemInOutput(int item) const {
        Rect r = items[item];
        r.y += originY;
        return r;
    }
};

Layout computeLayout(int outputWidth, int outputHeight, Side side = Side::Left);

// Side of the square corner handle in pixels (0 if the output size is unknown)
int handleSize(int outputWidth, int outputHeight);

// Handle rectangle in output pixels: bottom-left corner of the output
Rect handleRect(int outputWidth, int outputHeight);
const char* itemLabel(int item);

class TouchMenu
{
public:
    // Window drawable size in pixels. Set before feeding events.
    void setOutputSize(int width, int height);

    // Whether the renderer can draw the full-width surface the right side needs.
    // When false the edge swipe opens the left panel instead. Default true.
    void setRightPanelAllowed(bool allowed) { m_RightPanelAllowed = allowed; }

    // Side of the open (or last opened) menu
    Side side() const { return m_Side; }

    Event fingerDown(int64_t id, float x, float y, uint32_t nowMs);
    Event fingerMove(int64_t id, float x, float y, uint32_t nowMs);
    Event fingerUp(int64_t id, float x, float y, uint32_t nowMs);

    // The platform cancelled a contact: like an up that activates nothing.
    // (SDL2 has no such event; kept for SDL3 style cancels.)
    Event fingerCancel(int64_t id, uint32_t nowMs);

    // Call periodically while needsTick() is true. May return Open or Close.
    Event tick(uint32_t nowMs);

    // Forget all fingers and close the menu
    void reset();

    bool isOpen() const { return m_Open; }

    // True while a hold is being timed, the menu is open or the handle is visible
    bool needsTick() const { return m_Open || m_Armed || m_HandleVisible || m_EdgeActive; }

    // True while the corner handle should be drawn (never while the menu is open)
    bool handleVisible() const { return m_HandleVisible && !m_Open; }

    // Item that the active finger went down on and is still over, or -1
    int highlightedItem() const;

    // Number of fingers that count towards the gesture (not swallowed)
    int gestureFingerCount() const;

    // Item under a point in normalized coordinates, or -1 (outside every item)
    int hitTest(float x, float y) const;

private:
    struct Finger {
        int64_t id;
        float startX, startY;
        float x, y;
        bool ignored;
        bool onHandle;
    };

    Finger* find(int64_t id);
    bool moved(const Finger& finger) const;
    void ignoreAllFingers();
    void closeMenu();
    void openMenu(uint32_t nowMs, Side side);
    bool edgeFinger(int64_t id) const { return m_EdgeActive && (id == m_EdgeA || (m_EdgeHaveB && id == m_EdgeB)); }
    void cancelEdge() { m_EdgeActive = false; m_EdgeHaveB = false; }
    bool evaluateEdge(uint32_t nowMs);
    void noteActivity(uint32_t nowMs);
    bool inHandle(float x, float y) const;

    int m_OutputWidth = 0, m_OutputHeight = 0;
    std::vector<Finger> m_Fingers;
    bool m_Open = false;
    Side m_Side = Side::Left;
    bool m_RightPanelAllowed = true;
    bool m_EdgeActive = false, m_EdgeHaveB = false;
    int64_t m_EdgeA = 0, m_EdgeB = 0;
    uint32_t m_EdgeFirstMs = 0;
    bool m_HandleVisible = false;
    uint32_t m_LastActivityMs = 0;
    bool m_Armed = false;
    bool m_Cancelled = false;
    uint32_t m_ArmedAtMs = 0;
    uint32_t m_LastTouchMs = 0;
    bool m_HaveActive = false;
    int64_t m_ActiveId = 0;
    int m_PressItem = -1;
    int m_CurrentItem = -1;
};

}
