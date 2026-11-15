#pragma once
// Process-wide state the QML needs: command-line flags, the font family, and keyboard mode
// (focus tint shows only after a key moved focus, never after a click: design-system.md 4.17).
#include <QObject>
#include <QRect>
#include <QStringList>

#include "globalshortcut.h"

class AppState : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString fontFamily MEMBER m_fontFamily CONSTANT)
  Q_PROPERTY(bool keyboardMode READ keyboardMode NOTIFY keyboardModeChanged)
  Q_PROPERTY(bool loginEnabled READ loginEnabled WRITE setLoginEnabled NOTIFY loginChanged)
  Q_PROPERTY(QString loginError READ loginError NOTIFY loginChanged)
  Q_PROPERTY(QString homePath READ homePath CONSTANT)
  // The menu shortcut can be registered (Linux: the GlobalShortcuts portal answered); else the row is off.
  Q_PROPERTY(bool globalShortcuts READ globalShortcuts NOTIFY globalShortcutsChanged)
public:
  AppState(QStringList args, QString fontFamily, QObject *parent = nullptr);
  Q_INVOKABLE QString arg(const QString &name, const QString &def = QString()) const;
  Q_INVOKABLE bool flag(const QString &name) const;
  // Usable area (no panels or taskbar) of the screen that holds `window`, in logical pixels.
  Q_INVOKABLE QRect workArea(QObject *window) const;
  bool keyboardMode() const { return m_keyboardMode; }
  Q_INVOKABLE void copy(const QString &text) const;
  Q_INVOKABLE void reveal(const QString &path) const;
  // Open at Login (shell.md 6.4): status is whether the autostart entry exists; there is no approval state.
  bool loginEnabled() const;
  void setLoginEnabled(bool on);
  QString loginError() const { return m_loginError; }
  QString homePath() const;
  bool globalShortcuts() const { return m_shortcut.available(); }
  // shell.md 5.2 apply(combo): the stored {key, modifiers} or null; shortcutRefused when the desktop says no.
  Q_INVOKABLE void applyShortcut(const QVariant &combo) { m_shortcut.apply(combo); }

signals:
  void keyboardModeChanged();
  void loginChanged();
  void globalShortcutsChanged();
  void shortcutActivated();
  void shortcutRefused();

protected:
  bool eventFilter(QObject *watched, QEvent *event) override;

private:
  QStringList m_args;
  QString m_fontFamily;
  bool m_keyboardMode = false;
  QString m_loginError;
  GlobalShortcut m_shortcut;
};
