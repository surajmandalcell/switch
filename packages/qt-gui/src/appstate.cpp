#include "appstate.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QEvent>
#include <QFileInfo>
#include <QGuiApplication>
#include <QSaveFile>
#include <QSettings>
#include <QStandardPaths>
#include <QUrl>
#include <QScreen>
#include <QWindow>
#include <QKeyEvent>

AppState::AppState(QStringList args, QString fontFamily, QObject *parent)
    : QObject(parent), m_args(std::move(args)), m_fontFamily(std::move(fontFamily)) {
  connect(&m_shortcut, &GlobalShortcut::availableChanged, this, &AppState::globalShortcutsChanged);
  connect(&m_shortcut, &GlobalShortcut::activated, this, &AppState::shortcutActivated);
  connect(&m_shortcut, &GlobalShortcut::refused, this, &AppState::shortcutRefused);
}

QString AppState::arg(const QString &name, const QString &def) const {
  const QString key = "--" + name;
  for (int i = 0; i < m_args.size(); ++i) {
    if (m_args[i] == key && i + 1 < m_args.size()) return m_args[i + 1];
    if (m_args[i].startsWith(key + "=")) return m_args[i].mid(key.size() + 1);
  }
  return def;
}

bool AppState::flag(const QString &name) const { return m_args.contains("--" + name); }

QRect AppState::workArea(QObject *window) const {
  auto *w = qobject_cast<QWindow *>(window);
  QScreen *s = w && w->screen() ? w->screen() : QGuiApplication::primaryScreen();
  return s ? s->availableGeometry() : QRect();
}

QString AppState::homePath() const { return QDir::homePath(); }

void AppState::copy(const QString &text) const { QGuiApplication::clipboard()->setText(text); }

// settings.md 2.7 Reveal: the file manager at that folder (the Mac selects the item; a plain folder open is
// what every Linux and Windows file manager supports through one call).
void AppState::reveal(const QString &path) const { QDesktopServices::openUrl(QUrl::fromLocalFile(path)); }

// shell.md 6.4 for Linux and Windows: an XDG autostart entry or the HKCU Run value, both starting `--background`.
#ifdef Q_OS_WIN
static const char *kRunKey = "HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run";
#else
static QString autostartFile() {
  return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/autostart/switch.desktop";
}
#endif

bool AppState::loginEnabled() const {
#ifdef Q_OS_WIN
  return QSettings(kRunKey, QSettings::NativeFormat).contains("Switch");
#else
  // settings.md 8.3: the entry exists and is not Hidden=true.
  QFile f(autostartFile());
  return f.open(QIODevice::ReadOnly) && !("\n" + f.readAll()).contains("\nHidden=true");
#endif
}

void AppState::setLoginEnabled(bool on) {
  m_loginError.clear();
  const QString exe = QDir::toNativeSeparators(QCoreApplication::applicationFilePath());
#ifdef Q_OS_WIN
  QSettings key(kRunKey, QSettings::NativeFormat);
  if (on) key.setValue("Switch", "\"" + exe + "\" --background");
  else key.remove("Switch");
  key.sync();
  if (key.status() != QSettings::NoError) m_loginError = "the Run registry key could not be written";
#else
  const QString path = autostartFile();
  // An AppImage runs from a temporary mount; APPIMAGE names the file the user keeps.
  const QString target = qEnvironmentVariableIsSet("APPIMAGE") ? qEnvironmentVariable("APPIMAGE") : exe;
  if (on) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    const QByteArray body = "[Desktop Entry]\nType=Application\nName=Switch\nExec=" + GlobalShortcut::desktopExec(target) +
                            " --background\nX-GNOME-Autostart-enabled=true\n";
    if (!f.open(QIODevice::WriteOnly) || f.write(body) != body.size() || !f.commit()) m_loginError = f.errorString();
  } else if (QFileInfo::exists(path) && !QFile::remove(path)) {
    m_loginError = "the autostart file could not be removed";
  }
#endif
  emit loginChanged();
}

bool AppState::eventFilter(QObject *watched, QEvent *event) {
  bool next = m_keyboardMode;
  if (event->type() == QEvent::KeyPress) {
    const int k = static_cast<QKeyEvent *>(event)->key();
    if (k == Qt::Key_Tab || k == Qt::Key_Backtab || k == Qt::Key_Up || k == Qt::Key_Down) next = true;
  } else if (event->type() == QEvent::MouseButtonPress) {
    next = false;
  }
  if (next != m_keyboardMode) {
    m_keyboardMode = next;
    emit keyboardModeChanged();
  }
  return QObject::eventFilter(watched, event);
}
