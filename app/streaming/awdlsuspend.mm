#include "awdlsuspend.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QStandardPaths>

#include <SDL.h>

#include <chrono>

#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <pwd.h>
#include <spawn.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char** environ;

namespace {

const char* const kInterface = "awdl0";
const char* const kSudoersPath = "/etc/sudoers.d/vibelight-awdl";
const auto kWatchInterval = std::chrono::seconds(2);

// Runs a program with no shell and returns its exit status (-1 if it could not run).
int runQuiet(const char* const argv[])
{
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t pid;
    int err = posix_spawn(&pid, argv[0], &actions, nullptr, const_cast<char* const*>(argv), environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        return -1;
    }

    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            return -1;
        }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

QString currentUserName()
{
    struct passwd* pw = getpwuid(getuid());
    return pw != nullptr ? QString::fromUtf8(pw->pw_name) : QString();
}

// AppleScript "do shell script ... with administrator privileges" shows the
// standard macOS password prompt. The script contains no user-controlled text
// other than a validated user name.
bool runAsAdmin(const QString& shellScript)
{
    QString escaped = shellScript;
    escaped.replace("\\", "\\\\").replace("\"", "\\\"");
    QByteArray appleScript = QStringLiteral("do shell script \"%1\" with administrator privileges").arg(escaped).toUtf8();

    const char* argv[] = { "/usr/bin/osascript", "-e", appleScript.constData(), nullptr };
    return runQuiet(argv) == 0;
}

}

AwdlSuspendHold::AwdlSuspendHold(bool enabled)
{
    if (!enabled) {
        return;
    }

    if (!isInterfaceUp()) {
        // Already down (or no AWDL on this Mac): nothing to restore later.
        SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "AWDL is already down; leaving it as it is");
        return;
    }

    if (!setInterfaceUp(false)) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
                    "Could not pause AWDL. Turn the setting off and on again in Settings to reinstall its permission.");
        return;
    }

    m_TookDown = true;
    QFile marker(markerPath());
    QDir().mkpath(QFileInfo(marker).absolutePath());
    if (marker.open(QIODevice::WriteOnly)) {
        marker.close();
    }

    SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "AWDL paused for this stream");
    m_Watcher = std::thread(&AwdlSuspendHold::watch, this);
}

AwdlSuspendHold::~AwdlSuspendHold()
{
    if (m_Watcher.joinable()) {
        {
            std::lock_guard<std::mutex> lock(m_Mutex);
            m_Stop = true;
        }
        m_Cond.notify_all();
        m_Watcher.join();
    }

    if (m_TookDown) {
        if (setInterfaceUp(true)) {
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "AWDL restored");
            QFile::remove(markerPath());
        }
        else {
            // Keep the marker so the next launch tries again.
            SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Could not restore AWDL; it will be retried on next launch");
        }
    }
}

void AwdlSuspendHold::watch()
{
    std::unique_lock<std::mutex> lock(m_Mutex);
    while (!m_Cond.wait_for(lock, kWatchInterval, [this] { return m_Stop.load(); })) {
        // Reading the flags is a cheap ioctl; sudo only runs when macOS raised it again.
        if (isInterfaceUp()) {
            SDL_LogInfo(SDL_LOG_CATEGORY_APPLICATION, "macOS brought AWDL back up; pausing it again");
            setInterfaceUp(false);
        }
    }
}

bool AwdlSuspendHold::isInterfaceUp(const char* name)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return false;
    }

    struct ifreq ifr = {};
    strlcpy(ifr.ifr_name, name, sizeof(ifr.ifr_name));
    bool up = ioctl(fd, SIOCGIFFLAGS, &ifr) == 0 && (ifr.ifr_flags & IFF_UP) != 0;
    close(fd);
    return up;
}

bool AwdlSuspendHold::setInterfaceUp(bool up)
{
    const char* argv[] = { "/usr/bin/sudo", "-n", "/sbin/ifconfig", kInterface, up ? "up" : "down", nullptr };
    return runQuiet(argv) == 0;
}

bool AwdlSuspendHold::isHelperInstalled()
{
    // "sudo -n -l <command>" succeeds only if the command may run without a password.
    const char* argv[] = { "/usr/bin/sudo", "-n", "-l", "/sbin/ifconfig", kInterface, "down", nullptr };
    return runQuiet(argv) == 0;
}

QString AwdlSuspendHold::sudoersRule(const QString& userName)
{
    static const QRegularExpression safeName(QStringLiteral("^[A-Za-z0-9_][A-Za-z0-9_.-]*$"));
    if (!safeName.match(userName).hasMatch()) {
        return QString();
    }

    return QStringLiteral("%1 ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down\n"
                          "%1 ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 up\n").arg(userName);
}

bool AwdlSuspendHold::installHelper()
{
    QString rule = sudoersRule(currentUserName());
    if (rule.isEmpty()) {
        SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "Cannot install the AWDL permission for this user name");
        return false;
    }

    // Write to a temp file, validate it with visudo, then move it into place.
    // A rule that fails validation is never installed, so sudo cannot be broken.
    QStringList lines = rule.trimmed().split('\n');
    QString script = QStringLiteral(
        "T=$(/usr/bin/mktemp) && "
        "/usr/bin/printf '%s\\n' '%1' '%2' > \"$T\" && "
        "/usr/sbin/visudo -cf \"$T\" && "
        "/usr/sbin/chown root:wheel \"$T\" && "
        "/bin/chmod 0440 \"$T\" && "
        "/bin/mv -f \"$T\" %3").arg(lines[0], lines[1], QString::fromUtf8(kSudoersPath));

    if (!runAsAdmin(script)) {
        return false;
    }
    return isHelperInstalled();
}

bool AwdlSuspendHold::uninstallHelper()
{
    if (!runAsAdmin(QStringLiteral("/bin/rm -f %1").arg(QString::fromUtf8(kSudoersPath)))) {
        return false;
    }
    return !isHelperInstalled();
}

void AwdlSuspendHold::recoverAfterCrash()
{
    if (!QFile::exists(markerPath())) {
        return;
    }

    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "The last stream ended without restoring AWDL; restoring it now");
    if (isInterfaceUp() || setInterfaceUp(true)) {
        QFile::remove(markerPath());
    }
}

QString AwdlSuspendHold::markerPath()
{
    return QDir(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation)).filePath("awdl-suspended");
}
