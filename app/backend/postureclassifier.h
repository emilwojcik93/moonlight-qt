#pragma once

// Client posture classification for the stream-posture-sync feature.
//
// Pure logic, no Qt: maps locally observable signals to one of five classes
// (desktop, laptop, tablet, handheld, phone) plus a confidence, decides what
// goes on the wire and when a runtime change is worth reporting. Detection of
// the signals lives in posturedetector.*; this file never touches the OS.
//
// Wire contract (all optional, ignored by stock hosts):
//   clientPosture=desktop|laptop|tablet|handheld|phone
//   clientTouch=0|1
//   clientDiagonalMm=50..800
//   clientDpi=72..800

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

constexpr int kMinDiagonalMm = 50;
constexpr int kMaxDiagonalMm = 800;
constexpr int kMinDpi = 72;
constexpr int kMaxDpi = 800;

// Screen diagonal thresholds used to split touch-primary devices
constexpr int kPhoneMaxDiagonalMm = 190;     // ~7.5 in
constexpr int kHandheldMaxDiagonalMm = 240;  // ~9.5 in

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

    // Only set when the OS reported them; never guessed. 0 = unknown.
    int diagonalMm = 0;
    int dpi = 0;
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
    int diagonalMm = 0;  // 0 = omit
    int dpi = 0;         // 0 = omit
};

const char* className(PostureClass cls);
bool parseClassName(const std::string& name, PostureClass& out);

// Tablet, handheld and phone are the classes the host treats as touch-primary
inline bool isTouchPrimary(PostureClass cls)
{
    return cls == PostureClass::Tablet || cls == PostureClass::Handheld || cls == PostureClass::Phone;
}

inline bool diagonalPlausible(int mm) { return mm >= kMinDiagonalMm && mm <= kMaxDiagonalMm; }
inline bool dpiPlausible(int dpi) { return dpi >= kMinDpi && dpi <= kMaxDpi; }

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
// "clientPosture=tablet&clientTouch=1&clientDiagonalMm=305&clientDpi=160".
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

} // namespace posture
