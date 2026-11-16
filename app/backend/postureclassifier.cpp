#include "postureclassifier.h"

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

static PostureClass touchPrimaryClass(int diagonalMm)
{
    if (!diagonalPlausible(diagonalMm)) {
        return PostureClass::Tablet;
    }
    if (diagonalMm <= kPhoneMaxDiagonalMm) {
        return PostureClass::Phone;
    }
    if (diagonalMm <= kHandheldMaxDiagonalMm) {
        return PostureClass::Handheld;
    }
    return PostureClass::Tablet;
}

Result classify(const Signals& s)
{
    Result r;
    r.touch = s.hasTouchscreen;

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

    if (!s.hasTouchscreen) {
        // Nothing to touch: never a touch class, whatever the OS says
        r.cls = (s.portable.value_or(false)) ? PostureClass::Laptop : PostureClass::Desktop;
        r.confidence = (tabletSignal && *s.osTabletMode) ? Confidence::Low : Confidence::High;
        return r;
    }

    if (trustedTablet) {
        if (*s.osTabletMode) {
            r.cls = touchPrimaryClass(s.diagonalMm);
        }
        else {
            r.cls = PostureClass::Laptop;
        }
        r.confidence = conflict ? Confidence::Medium : Confidence::High;
        return r;
    }

    // No usable OS tablet signal: touchscreen presence plus input devices
    if (!s.hasKeyboard && !s.hasPointer) {
        r.cls = touchPrimaryClass(s.diagonalMm);
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
    p.diagonalMm = diagonalPlausible(sig.diagonalMm) ? sig.diagonalMm : 0;
    p.dpi = dpiPlausible(sig.dpi) ? sig.dpi : 0;
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
    if (diagonalPlausible(p.diagonalMm)) {
        q += "&clientDiagonalMm=" + std::to_string(p.diagonalMm);
    }
    if (dpiPlausible(p.dpi)) {
        q += "&clientDpi=" + std::to_string(p.dpi);
    }
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
    return isTouchPrimary(a.cls) != isTouchPrimary(b.cls) || a.touch != b.touch;
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

} // namespace posture
