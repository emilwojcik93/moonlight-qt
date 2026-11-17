#include "touchmenu.h"

#include <algorithm>
#include <cmath>

namespace touchmenu {

namespace {

// Share of the output height used by one item, a little above the minimum
constexpr float ItemHeightFraction = 0.13f;

// Longest label, used to size the font so that every label fits its item
constexpr int LongestLabelChars = 17; // "Toggle statistics"

}

const char* itemLabel(int item)
{
    switch (item) {
    case ItemDisconnect:  return "Disconnect";
    case ItemToggleStats: return "Toggle statistics";
    case ItemCloseMenu:   return "Close menu";
    }
    return "";
}

Layout computeLayout(int outputWidth, int outputHeight)
{
    Layout layout;
    if (outputWidth <= 0 || outputHeight <= 0) {
        return layout;
    }

    int pad = std::max(4, (int)std::lround(outputHeight * 0.02));
    int itemHeight = (int)std::ceil(outputHeight * ItemHeightFraction);
    int minHeight = (int)std::ceil(outputHeight * MinItemHeightFraction);
    itemHeight = std::max(itemHeight, minHeight);

    int surfaceWidth = std::min(outputWidth, std::max(outputWidth * 45 / 100, 480));
    int surfaceHeight = ItemCount * itemHeight + (ItemCount + 1) * pad;
    if (surfaceHeight > outputHeight) {
        // Degenerate (tiny) output: shrink to fit, the items may get shorter
        // than the minimum there.
        pad = std::max(1, outputHeight / 40);
        itemHeight = (outputHeight - (ItemCount + 1) * pad) / ItemCount;
        surfaceHeight = ItemCount * itemHeight + (ItemCount + 1) * pad;
    }
    if (itemHeight <= 0 || surfaceWidth <= 2 * pad) {
        return layout;
    }

    int itemWidth = surfaceWidth - 2 * pad;
    layout.valid = true;
    layout.surfaceWidth = surfaceWidth;
    layout.surfaceHeight = surfaceHeight;
    layout.border = std::max(2, itemHeight / 24);
    for (int i = 0; i < ItemCount; i++) {
        layout.items[i].x = pad;
        layout.items[i].y = pad + i * (itemHeight + pad);
        layout.items[i].w = itemWidth;
        layout.items[i].h = itemHeight;
    }

    int byHeight = (int)std::lround(itemHeight * 0.40);
    int byWidth = (int)std::lround(itemWidth / (LongestLabelChars * 0.70));
    layout.fontPixels = std::max(12, std::min(byHeight, byWidth));
    return layout;
}

int handleSize(int outputWidth, int outputHeight)
{
    if (outputWidth <= 0 || outputHeight <= 0) {
        return 0;
    }

    int size = std::max(HandleMinPixels, (int)std::lround(outputHeight * HandleHeightFraction));
    return std::min(size, std::min(outputWidth, outputHeight));
}

Rect handleRect(int outputWidth, int outputHeight)
{
    Rect rect;
    int size = handleSize(outputWidth, outputHeight);
    rect.x = 0;
    rect.y = outputHeight - size;
    rect.w = rect.h = size;
    return rect;
}

void TouchMenu::setOutputSize(int width, int height)
{
    m_OutputWidth = width;
    m_OutputHeight = height;
}

TouchMenu::Finger* TouchMenu::find(int64_t id)
{
    for (auto& finger : m_Fingers) {
        if (finger.id == id) {
            return &finger;
        }
    }
    return nullptr;
}

bool TouchMenu::moved(const Finger& finger) const
{
    float w = m_OutputWidth > 0 ? (float)m_OutputWidth : 1.0f;
    float h = m_OutputHeight > 0 ? (float)m_OutputHeight : 1.0f;
    float dx = (finger.x - finger.startX) * w;
    float dy = (finger.y - finger.startY) * h;
    float limit = MoveFraction * std::min(w, h);
    return std::sqrt(dx * dx + dy * dy) >= limit;
}

void TouchMenu::ignoreAllFingers()
{
    for (auto& finger : m_Fingers) {
        finger.ignored = true;
    }
}

bool TouchMenu::inHandle(float x, float y) const
{
    if (m_OutputWidth <= 0 || m_OutputHeight <= 0) {
        return false;
    }

    Rect r = handleRect(m_OutputWidth, m_OutputHeight);
    int px = (int)std::floor(x * m_OutputWidth);
    int py = (int)std::floor(y * m_OutputHeight);
    return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
}

void TouchMenu::noteActivity(uint32_t nowMs)
{
    m_HandleVisible = true;
    m_LastActivityMs = nowMs;
}

void TouchMenu::openMenu(uint32_t nowMs)
{
    m_Armed = false;
    m_Open = true;
    m_HandleVisible = false;
    m_LastTouchMs = nowMs;
    m_HaveActive = false;
    m_PressItem = m_CurrentItem = -1;
    ignoreAllFingers();
}

void TouchMenu::closeMenu()
{
    m_Open = false;
    m_HandleVisible = false;
    m_Armed = false;
    m_Cancelled = false; // Remaining fingers are ignored, so they cannot re-arm
    m_HaveActive = false;
    m_PressItem = -1;
    m_CurrentItem = -1;
    ignoreAllFingers();
}

int TouchMenu::gestureFingerCount() const
{
    int count = 0;
    for (const auto& finger : m_Fingers) {
        if (!finger.ignored) {
            count++;
        }
    }
    return count;
}

int TouchMenu::hitTest(float x, float y) const
{
    Layout layout = computeLayout(m_OutputWidth, m_OutputHeight);
    if (!layout.valid) {
        return -1;
    }

    int px = (int)std::floor(x * m_OutputWidth);
    int py = (int)std::floor(y * m_OutputHeight);
    int localX = px;
    int localY = py - (m_OutputHeight - layout.surfaceHeight);
    for (int i = 0; i < ItemCount; i++) {
        const Rect& r = layout.items[i];
        if (localX >= r.x && localX < r.x + r.w && localY >= r.y && localY < r.y + r.h) {
            return i;
        }
    }
    return -1;
}

int TouchMenu::highlightedItem() const
{
    if (m_Open && m_HaveActive && m_PressItem >= 0 && m_CurrentItem == m_PressItem) {
        return m_PressItem;
    }
    return -1;
}

Event TouchMenu::fingerDown(int64_t id, float x, float y, uint32_t nowMs)
{
    Event result;

    // A repeated down for a known id replaces the old record
    m_Fingers.erase(std::remove_if(m_Fingers.begin(), m_Fingers.end(),
                                   [id](const Finger& f) { return f.id == id; }),
                    m_Fingers.end());
    if (m_HaveActive && m_ActiveId == id) {
        m_HaveActive = false;
    }

    // Decided before this touch makes the handle visible
    bool onHandle = !m_Open && m_HandleVisible && inHandle(x, y);

    Finger finger = { id, x, y, x, y, m_Open || onHandle, onHandle };
    m_Fingers.push_back(finger);

    if (m_Open) {
        m_LastTouchMs = nowMs;
        if (!m_HaveActive) {
            m_HaveActive = true;
            m_ActiveId = id;
            m_PressItem = m_CurrentItem = hitTest(x, y);
        }
        result.swallow = true;
        return result;
    }

    noteActivity(nowMs);
    result.swallow = onHandle;

    if (!m_Armed && !m_Cancelled && gestureFingerCount() >= HoldFingers) {
        // Fingers that already travelled too far (a scroll in progress)
        // do not start a hold.
        bool anyMoved = false;
        for (const auto& f : m_Fingers) {
            if (!f.ignored && moved(f)) {
                anyMoved = true;
            }
        }
        if (anyMoved) {
            m_Cancelled = true;
        }
        else {
            m_Armed = true;
            m_ArmedAtMs = nowMs;
        }
    }
    return result;
}

Event TouchMenu::fingerMove(int64_t id, float x, float y, uint32_t nowMs)
{
    Event result;
    Finger* finger = find(id);

    if (finger != nullptr) {
        finger->x = x;
        finger->y = y;
    }

    if (m_Open) {
        m_LastTouchMs = nowMs;
        if (m_HaveActive && m_ActiveId == id) {
            m_CurrentItem = hitTest(x, y);
        }
        result.swallow = true;
        return result;
    }

    noteActivity(nowMs);
    if (finger == nullptr) {
        return result;
    }

    result.swallow = finger->ignored;
    if (!finger->ignored && m_Armed && moved(*finger)) {
        m_Armed = false;
        m_Cancelled = true;
    }
    return result;
}

Event TouchMenu::fingerUp(int64_t id, float x, float y, uint32_t nowMs)
{
    Event result;
    Finger* finger = find(id);
    bool wasIgnored = finger != nullptr ? finger->ignored : false;
    bool tappedHandle = false;

    if (finger != nullptr) {
        finger->x = x;
        finger->y = y;
        tappedHandle = !m_Open && finger->onHandle && inHandle(x, y) && !moved(*finger);
        m_Fingers.erase(m_Fingers.begin() + (finger - m_Fingers.data()));
    }

    if (m_Open) {
        m_LastTouchMs = nowMs;
        result.swallow = true;
        if (m_HaveActive && m_ActiveId == id) {
            int pressItem = m_PressItem;
            int upItem = hitTest(x, y);
            m_HaveActive = false;
            m_PressItem = m_CurrentItem = -1;

            if (pressItem >= 0 && upItem == pressItem) {
                if (pressItem == ItemCloseMenu) {
                    result.type = EventType::Close;
                }
                else {
                    result.type = EventType::Activate;
                    result.item = pressItem;
                }
                closeMenu();
            }
            else if (pressItem < 0 && upItem < 0) {
                result.type = EventType::Close;
                closeMenu();
            }
        }
        return result;
    }

    result.swallow = wasIgnored;
    if (gestureFingerCount() < HoldFingers) {
        m_Armed = false;
        m_Cancelled = false;
    }

    if (tappedHandle) {
        openMenu(nowMs);
        result.type = EventType::Open;
        result.swallow = true;
    }
    else {
        noteActivity(nowMs);
    }
    return result;
}

Event TouchMenu::fingerCancel(int64_t id, uint32_t nowMs)
{
    Event result;
    Finger* finger = find(id);
    bool wasIgnored = finger != nullptr ? finger->ignored : false;

    if (finger != nullptr) {
        m_Fingers.erase(m_Fingers.begin() + (finger - m_Fingers.data()));
    }

    if (m_Open) {
        m_LastTouchMs = nowMs;
        result.swallow = true;
        if (m_HaveActive && m_ActiveId == id) {
            m_HaveActive = false;
            m_PressItem = m_CurrentItem = -1;
        }
        return result;
    }

    result.swallow = wasIgnored;
    if (gestureFingerCount() < HoldFingers) {
        m_Armed = false;
        m_Cancelled = false;
    }
    noteActivity(nowMs);
    return result;
}

Event TouchMenu::tick(uint32_t nowMs)
{
    Event result;

    if (m_Open) {
        if ((uint32_t)(nowMs - m_LastTouchMs) >= IdleMs) {
            closeMenu();
            result.type = EventType::Close;
            result.swallow = true;
        }
    }
    else if (m_Armed && (uint32_t)(nowMs - m_ArmedAtMs) >= HoldMs) {
        openMenu(nowMs);
        result.type = EventType::Open;
        result.swallow = true;
    }
    else if (m_HandleVisible && (uint32_t)(nowMs - m_LastActivityMs) >= HandleHideMs) {
        m_HandleVisible = false;
        // Whatever is still tracked has had no event for a long time: its up
        // was probably lost. Swallowed fingers stay until they lift.
        m_Fingers.erase(std::remove_if(m_Fingers.begin(), m_Fingers.end(),
                                       [](const Finger& f) { return !f.ignored; }),
                        m_Fingers.end());
        m_Armed = false;
        m_Cancelled = false;
    }
    return result;
}

void TouchMenu::reset()
{
    m_Fingers.clear();
    m_Open = false;
    m_HandleVisible = false;
    m_Armed = false;
    m_Cancelled = false;
    m_HaveActive = false;
    m_PressItem = -1;
    m_CurrentItem = -1;
}

}
