#pragma once
// The menu shortcut (shell.md 5.2, settings.md 8.4): one system-wide shortcut that toggles the tray popover.
// Linux registers it through the XDG GlobalShortcuts portal, else with an X11 key grab (X11 or XWayland);
// elsewhere `available` stays false.
#include <QObject>
#include <QVariant>
#ifdef SWITCH_DBUS
#include <QDBusMessage>
#include <QHash>
#include <functional>
#endif
#ifdef SWITCH_XCB
struct xcb_connection_t;
#endif

class GlobalShortcut : public QObject {
  Q_OBJECT
public:
  explicit GlobalShortcut(QObject *parent = nullptr);
  ~GlobalShortcut() override;
  bool available() const { return m_available; }
  // `combo` is the stored settings.md value {keyCode: Mac virtual key, modifiers: Carbon mask} or null.
  // No-op when unchanged; null or an unknown key only unregisters.
  void apply(const QVariant &combo);
  // The shortcut in the XDG shortcuts format, such as "CTRL+ALT+s"; empty when the key has no keysym name.
  static QString xdgTrigger(int qtKey, int carbonModifiers);
  // Mac virtual key code (kVK_*) for a Qt key and back; -1 and 0 when the key has no counterpart.
  static int macKeyCode(int qtKey);
  static int qtKey(int macKeyCode);
  // The X11 keysym for a Qt key (0 when none).
  static uint keysym(int qtKey);
  // A program path as a quoted Exec value (Desktop Entry spec "The Exec key").
  static QByteArray desktopExec(const QString &path);
  // In an AppImage: the user's desktop entry under the app id with Exec at $APPIMAGE, rewritten when the
  // path changes (integration tools rename the shipped entry, and the portal looks the app id up).
  static void writeAppImageEntry();

signals:
  void availableChanged();
  void activated();
  void refused();

#ifdef SWITCH_DBUS
private slots:
  void onResponse(const QDBusMessage &msg);
  void onActivated(const QDBusMessage &msg);

private:
  QString request(const QString &method, QVariantList args, std::function<void(uint, const QVariantMap &)> done);
  void bind();
  void closeSession();
  QHash<QString, std::function<void(uint, const QVariantMap &)>> m_requests;   // request path -> handler
  QString m_session;
  int m_generation = 0;
  bool m_portal = false;
#endif
#ifdef SWITCH_XCB
private slots:
  void onXcbEvent();

private:
  void startX11();
  bool grabX11();
  void ungrabX11();
  xcb_connection_t *m_xcb = nullptr;
  uint m_root = 0;
  uint m_keycode = 0;      // grabbed key, 0 when none
  uint m_xmods = 0;
  uint m_lastRelease = 0;  // auto-repeat sends a release and a press with the same time
#endif

private:
  bool m_available = false;
  QString m_trigger;
  int m_key = 0;   // Qt key of the applied combo
  int m_mods = 0;  // its Carbon mask
};
