#pragma once

#include <QString>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

// Keeps the AWDL interface (awdl0: AirDrop, AirPlay, Handoff, iPhone Mirroring)
// down for the lifetime of the object, then restores it.
//
// AWDL shares the Mac's single Wi-Fi radio with the connection to the router.
// While it is up, the radio periodically leaves the router's channel to listen
// for nearby Apple devices, which shows up as 20-100 ms latency spikes in the
// stream. Taking awdl0 down removes the spikes, and bringing it back up when the
// stream ends restores AirDrop and Continuity.
//
// Changing the interface needs root. installHelper() asks for the user's admin
// password once and adds a sudoers rule that allows exactly
// "/sbin/ifconfig awdl0 down" and "/sbin/ifconfig awdl0 up" without a password;
// the hold then runs those through "sudo -n", which never prompts. Without the
// rule the hold logs a warning and the stream continues normally.
//
// macOS can bring awdl0 back up by itself (for example when AirDrop is opened),
// so a watcher thread takes it down again while the hold is active. A marker
// file records that the interface was taken down, so recoverAfterCrash() can
// restore it on the next launch if the process died mid-stream.
class AwdlSuspendHold
{
public:
    explicit AwdlSuspendHold(bool enabled);
    ~AwdlSuspendHold();

    AwdlSuspendHold(const AwdlSuspendHold&) = delete;
    AwdlSuspendHold& operator=(const AwdlSuspendHold&) = delete;

    // True when this hold took awdl0 down and will restore it.
    bool isHolding() const { return m_TookDown.load(); }

    // Interface state, read without privileges. Returns false if awdl0 does not exist.
    static bool isInterfaceUp(const char* name = "awdl0");

    // Whether the sudoers rule lets "sudo -n" run the ifconfig commands.
    static bool isHelperInstalled();

    // Install or remove the sudoers rule. Each shows one macOS admin prompt.
    // Return false if the user cancels or the rule fails validation.
    static bool installHelper();
    static bool uninstallHelper();

    // Called once at startup: restore AWDL if a previous run died while holding it.
    static void recoverAfterCrash();

    // The exact rule text written to /etc/sudoers.d (exposed for tests).
    // Returns an empty string for a user name that is not safe to embed.
    static QString sudoersRule(const QString& userName);

    static QString markerPath();

private:
    static bool setInterfaceUp(bool up);
    void watch();

    std::atomic<bool> m_TookDown{false};
    std::atomic<bool> m_Stop{false};
    std::mutex m_Mutex;
    std::condition_variable m_Cond;
    std::thread m_Watcher;
};
