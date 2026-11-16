#pragma once

// Client posture classification for the stream-posture-sync feature.
//
// Pure logic, no Qt: maps locally observable signals to one of five classes
// (desktop, laptop, tablet, handheld, phone) plus a confidence, decides what
// goes on the wire and when a runtime change is worth reporting. Detection of
// the signals lives in posturedetector.*; this file never touches the OS.
//
// Wire contract v2 (all optional, ignored by stock hosts):
//   clientPosture=desktop|laptop|tablet|handheld|phone
//   clientTouch=0|1
// The class never depends on the screen size, DPI or aspect: only the device
// type and keyboard state matter. Touch-primary means "docked touch keyboard
// wanted". This client sends tablet for every touch-primary state; handheld and
// phone exist for other clients and are only parsed here.

#include <chrono>
#include <optional>
#include <string>

namespace posture {

enum class PostureClass {
    Desktop,
    Laptop,
    Tablet,
    Handheld,
    Phone,
};

enum class Confidence {
    Low,
    Medium,
    High,
};

// User choice (mirrors StreamingPreferences::PostureMode)
enum class Mode {
    Auto,
    AlwaysTablet,
    Never,
};

struct Signals {
    // OS says the device is in tablet/slate mode (KWin tabletMode, Windows
    // SM_CONVERTIBLESLATEMODE == 0). Unset when the OS has no such notion.
    std::optional<bool> osTabletMode;
    // OS says it can report tablet mode at all (KWin tabletModeAvailable).
    // KWin on some 2-in-1s reports tabletMode=true with this false; the tablet
    // signal is then not trustworthy.
    std::optional<bool> osTabletModeAvailable;

    bool hasTouchscreen = false;
    bool hasKeyboard = false;
    bool hasPointer = false;

    // Chassis says portable (laptop, convertible, detachable). Unset = unknown.
    std::optional<bool> portable;
};

struct Result {
    PostureClass cls = PostureClass::Desktop;
    Confidence confidence = Confidence::Low;
    bool touch = false;
};

// What goes on the wire. valid == false means "send nothing".
struct Payload {
    bool valid = false;
    PostureClass cls = PostureClass::Desktop;
    bool touch = false;
};

const char* className(PostureClass cls);
bool parseClassName(const std::string& name, PostureClass& out);

// Tablet, handheld and phone are the classes the host treats as touch-primary
inline bool isTouchPrimary(PostureClass cls)
{
    return cls == PostureClass::Tablet || cls == PostureClass::Handheld || cls == PostureClass::Phone;
}

// Classify from signals alone (the Auto path).
Result classify(const Signals& sig);

// Build the payload for a user mode: Never and (on launch) a non-touch desktop
// yield an invalid payload, i.e. nothing is sent; callers must check
// Payload::valid. AlwaysTablet overrides detection.
//
// For the launch/resume request (runtimeUpdate == false) a non-touch desktop
// produces no payload. For a runtime update the new state is always explicit,
// so the host can leave touch posture again.
Payload makePayload(const Signals& sig, Mode mode, bool runtimeUpdate);

// Result for a given mode (override-aware), used by makePayload and by callers
// that want the class for logging.
Result resolve(const Signals& sig, Mode mode);

// Query string without leading '&', e.g.
// "clientPosture=tablet&clientTouch=1".
// Empty for an invalid payload.
std::string buildQuery(const Payload& payload);

// Decides whether a runtime posture change is worth sending: only when the
// touch-primary boundary is crossed or the touch-ness changes, and only after
// the new state has been stable for the debounce interval.
class UpdateGate {
public:
    using Clock = std::chrono::steady_clock;

    UpdateGate(const Payload& lastSent, std::chrono::milliseconds debounce)
        : m_Sent(normalize(lastSent)), m_Debounce(debounce) {}

    // Feed the latest observation. Returns the payload to send, if any.
    std::optional<Payload> observe(const Payload& current, Clock::time_point now);

private:
    static Payload normalize(Payload p);
    static bool differs(const Payload& a, const Payload& b);

    Payload m_Sent;
    std::chrono::milliseconds m_Debounce;
    std::optional<Payload> m_Candidate;
    Clock::time_point m_CandidateSince{};
};

// Decides when an accepted runtime update should be followed by an automatic
// resume of the stream. The host only rebuilds its virtual display on a
// resume, so after /posture succeeded the client reconnects once, when the
// touch-primary boundary was crossed relative to the posture the running
// display was created for (the "baseline", i.e. the launch payload of the
// current session).
//
// Safety rules, all pure logic so they can be tested:
//   - setting off: never
//   - nothing before the stream has run for armDelay (never while connecting)
//   - at most one restart per cooldown, across sessions (lastRestart is carried
//     into the next session's gate)
//   - a flip that was blocked by the cooldown is not lost: due() turns true when
//     the cooldown ends, but only if the latest accepted posture still differs
//     from the baseline, so a flap back to the baseline needs no restart
//   - never loops: the new session builds its gate from its own launch payload,
//     so the posture it started in is the baseline and nothing is due
class RestartGate {
public:
    using Clock = std::chrono::steady_clock;

    static constexpr std::chrono::milliseconds kDefaultCooldown{60000};
    static constexpr std::chrono::milliseconds kDefaultArmDelay{5000};

    RestartGate(bool enabled,
                const Payload& displayBaseline,
                Clock::time_point sessionStart,
                std::optional<Clock::time_point> lastRestart = std::nullopt,
                std::chrono::milliseconds cooldown = kDefaultCooldown,
                std::chrono::milliseconds armDelay = kDefaultArmDelay);

    // The host accepted this posture update.
    void accepted(const Payload& sent);

    // True when the session should be resumed now.
    bool due(Clock::time_point now) const;

private:
    static bool touchPrimary(const Payload& p);

    bool m_Enabled;
    bool m_BaselineTouch;
    bool m_LatestTouch;
    Clock::time_point m_ArmedAt;
    std::optional<Clock::time_point> m_LastRestart;
    std::chrono::milliseconds m_Cooldown;
};

} // namespace posture
