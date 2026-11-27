#include "postureclassifier.h"

#include <cctype>

#include <cstring>

namespace posture {

const char* className(PostureClass cls)
{
    switch (cls) {
    case PostureClass::Desktop:  return "desktop";
    case PostureClass::Laptop:   return "laptop";
    case PostureClass::Tablet:   return "tablet";
    case PostureClass::Handheld: return "handheld";
    case PostureClass::Phone:    return "phone";
    }
    return "desktop";
}

bool parseClassName(const std::string& name, PostureClass& out)
{
    static const PostureClass all[] = {
        PostureClass::Desktop, PostureClass::Laptop, PostureClass::Tablet,
        PostureClass::Handheld, PostureClass::Phone,
    };
    for (PostureClass cls : all) {
        if (name == className(cls)) {
            out = cls;
            return true;
        }
    }
    return false;
}

static bool startsWithNoCase(const std::string& name, const char* prefix)
{
    for (size_t i = 0; prefix[i]; i++) {
        if (i >= name.size() || std::tolower(static_cast<unsigned char>(name[i])) != prefix[i]) {
            return false;
        }
    }
    return true;
}

bool isBuiltinConnectorName(const std::string& name)
{
    return startsWithNoCase(name, "edp") || startsWithNoCase(name, "lvds") || startsWithNoCase(name, "dsi");
}

bool isExternalConnectorName(const std::string& name)
{
    return startsWithNoCase(name, "hdmi") || startsWithNoCase(name, "dp") ||
           startsWithNoCase(name, "displayport") || startsWithNoCase(name, "dvi") ||
           startsWithNoCase(name, "vga");
}

Result classify(const Signals& s)
{
    Result r;
    // A touchscreen behind a closed lid or a disabled panel is not a surface the
    // user can touch (docked laptop on an external display).
    const bool touchUsable = s.hasTouchscreen && s.builtinDisplayInUse.value_or(true);
    r.touch = touchUsable;

    const bool tabletSignal = s.osTabletMode.has_value();
    // KWin can report tabletModeAvailable=false even on a detachable 2-in-1
    // whose tabletMode property follows the real state (checked on a Dell
    // Latitude 5290 2-in-1: tabletMode=true with the keyboard detached).
    // So tabletMode=true is believed when a touchscreen exists, at lower
    // confidence if the OS says it cannot report tablet mode. tabletMode=false
    // with available=false is only 'unknown' and falls back to input devices.
    const bool conflict = tabletSignal && s.osTabletModeAvailable.has_value() &&
                          !*s.osTabletModeAvailable;
    const bool trustedTablet = tabletSignal && (!conflict || *s.osTabletMode);

    if (!touchUsable) {
        // Nothing to touch: never a touch class, whatever the OS says
        r.cls = (s.portable.value_or(false)) ? PostureClass::Laptop : PostureClass::Desktop;
        r.confidence = (tabletSignal && *s.osTabletMode) ? Confidence::Low : Confidence::High;
        return r;
    }

    if (s.handheldForm) {
        // A handheld gaming device has no keyboard to fold away; a docked keyboard
        // cannot be told apart reliably, so that case is left to the user override.
        r.cls = PostureClass::Handheld;
        r.confidence = Confidence::High;
        return r;
    }

    if (trustedTablet) {
        if (*s.osTabletMode) {
            // Tablet posture with a controller in hand is used like a handheld
            r.cls = s.hasGamepad ? PostureClass::Handheld : PostureClass::Tablet;
        }
        else {
            r.cls = PostureClass::Laptop;
        }
        r.confidence = conflict ? Confidence::Medium : Confidence::High;
        return r;
    }

    // No usable OS tablet signal: touchscreen presence plus input devices
    if (!s.hasKeyboard && !s.hasPointer) {
        r.cls = s.hasGamepad ? PostureClass::Handheld : PostureClass::Tablet;
        r.confidence = Confidence::Medium;
    }
    else {
        // Keyboard or pointer present: a touchscreen laptop, or a touch monitor
        r.cls = (s.portable.value_or(true)) ? PostureClass::Laptop : PostureClass::Desktop;
        // A tablet-mode claim that the devices contradict is worth flagging
        r.confidence = (conflict && *s.osTabletMode) ? Confidence::Low : Confidence::Medium;
    }
    return r;
}

Result resolve(const Signals& sig, Mode mode)
{
    if (mode == Mode::AlwaysTablet) {
        Result r;
        r.cls = PostureClass::Tablet;
        r.confidence = Confidence::High;
        r.touch = true;
        return r;
    }
    if (mode == Mode::AlwaysHandheld) {
        Result r;
        r.cls = PostureClass::Handheld;
        r.confidence = Confidence::High;
        r.touch = true;
        return r;
    }
    if (mode == Mode::AlwaysDesktop) {
        // Desktop mode on the host; touch stays a capability so the host keeps
        // the touch-sized display.
        Result r = classify(sig);
        r.cls = PostureClass::Laptop;
        r.confidence = Confidence::High;
        return r;
    }
    return classify(sig);
}

Payload makePayload(const Signals& sig, Mode mode, bool runtimeUpdate)
{
    Payload p;
    if (mode == Mode::Never) {
        return p;
    }

    const Result r = resolve(sig, mode);
    if (!runtimeUpdate && r.cls == PostureClass::Desktop && !r.touch) {
        return p;
    }

    p.valid = true;
    p.cls = r.cls;
    p.touch = r.touch;
    return p;
}

std::string buildQuery(const Payload& p)
{
    if (!p.valid) {
        return std::string();
    }

    std::string q = "clientPosture=";
    q += className(p.cls);
    q += p.touch ? "&clientTouch=1" : "&clientTouch=0";
    return q;
}

Payload UpdateGate::normalize(Payload p)
{
    // An omitted launch payload means desktop, no touch
    if (!p.valid) {
        p.valid = true;
        p.cls = PostureClass::Desktop;
        p.touch = false;
    }
    return p;
}

bool UpdateGate::differs(const Payload& a, const Payload& b)
{
    // The host mode decides: tablet <-> handheld (a controller attached or
    // removed) matters although both are touch-primary.
    return hostMode(a.cls) != hostMode(b.cls) || a.touch != b.touch;
}

std::optional<Payload> UpdateGate::observe(const Payload& current, Clock::time_point now)
{
    const Payload cur = normalize(current);

    if (!differs(cur, m_Sent)) {
        // Back at the last sent state (or a change that is not worth sending)
        m_Candidate.reset();
        return std::nullopt;
    }

    if (!m_Candidate || differs(cur, *m_Candidate)) {
        m_Candidate = cur;
        m_CandidateSince = now;
        return std::nullopt;
    }
    m_Candidate = cur;  // keep freshest size hints

    if (now - m_CandidateSince < m_Debounce) {
        return std::nullopt;
    }

    m_Sent = cur;
    m_Candidate.reset();
    return cur;
}

std::optional<bool> parseDisplayChange(const std::string& xml)
{
    static const std::string kAttr = "display_change=\"";
    const auto rootEnd = xml.find('>', xml.find("<root"));
    const auto at = xml.find(kAttr);
    if (at == std::string::npos || rootEnd == std::string::npos || at > rootEnd) {
        return std::nullopt;
    }
    const auto value = at + kAttr.size();
    if (value + 1 >= xml.size() || xml[value + 1] != '"') {
        return std::nullopt;
    }
    if (xml[value] == '1') {
        return true;
    }
    if (xml[value] == '0') {
        return false;
    }
    return std::nullopt;
}

RestartGate::RestartGate(bool enabled,
                         const Payload& displayBaseline,
                         Clock::time_point sessionStart,
                         std::optional<Clock::time_point> lastRestart,
                         std::chrono::milliseconds cooldown,
                         std::chrono::milliseconds armDelay)
    : m_Enabled(enabled),
      m_BaselineTouch(touchPrimary(displayBaseline)),
      m_LatestTouch(m_BaselineTouch),
      m_ArmedAt(sessionStart + armDelay),
      m_LastRestart(lastRestart),
      m_Cooldown(cooldown)
{
}

bool RestartGate::touchPrimary(const Payload& p)
{
    // An omitted payload (launch from a plain desktop) means not touch-primary
    return p.valid && isTouchPrimary(p.cls);
}

void RestartGate::accepted(const Payload& sent, std::optional<bool> hostDisplayChange)
{
    m_LatestTouch = touchPrimary(sent);
    m_HostDisplayChange = hostDisplayChange;
}

bool RestartGate::due(Clock::time_point now) const
{
    // The host knows whether its display still fits; trust it when it says so.
    const bool displayChange = m_HostDisplayChange ? *m_HostDisplayChange
                                                   : m_LatestTouch != m_BaselineTouch;
    if (!m_Enabled || !displayChange || now < m_ArmedAt) {
        return false;
    }
    return !m_LastRestart || now - *m_LastRestart >= m_Cooldown;
}

} // namespace posture
