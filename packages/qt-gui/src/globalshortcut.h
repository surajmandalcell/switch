#pragma once
// The menu shortcut (shell.md 5.2, settings.md 8.4): one system-wide shortcut that toggles the tray popover.
// Linux registers it through the XDG GlobalShortcuts portal; elsewhere `available` stays false.
#include <QObject>
#include <QVariant>
#ifdef SWITCH_DBUS
#include <QDBusMessage>
#include <QHash>
#include <functional>
#endif

class GlobalShortcut : public QObject {
  Q_OBJECT
public:
  explicit GlobalShortcut(QObject *parent = nullptr);
  bool available() const { return m_available; }
  // `combo` is the stored {key: Qt key, modifiers: Carbon mask} or null. No-op when unchanged; null only unregisters.
  void apply(const QVariant &combo);
  // The shortcut in the XDG shortcuts format, such as "CTRL+ALT+s"; empty when the key has no keysym name.
  static QString xdgTrigger(int qtKey, int carbonModifiers);

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
#endif

private:
  bool m_available = false;
  QString m_trigger;
};
