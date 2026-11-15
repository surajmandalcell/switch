#pragma once
// Desktop notifications (settings.md 8.2). Linux (SWITCH_DBUS): org.freedesktop.Notifications.Notify over D-Bus.
// title -> summary; subtitle on its own first line of the body; the same post id replaces the shown
// notification (replaces_id); a click (default action) raises the main window. There is no permission
// API on Linux, so posts always go out.
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>

class Notifier : public QObject {
  Q_OBJECT
public:
  explicit Notifier(QObject *parent = nullptr);
  bool available() const { return m_available; }
  // `alert` true: a quota alert (sound hint message-new-instant); false: an action message (suppress-sound).
  Q_INVOKABLE void post(const QString &id, const QString &title, const QString &subtitle, const QString &body,
                        bool alert);

signals:
  void activated();                                       // the user clicked a notification
  void fallback(const QString &title, const QString &text); // no notification service: show it on the tray

private slots:
  void onActionInvoked(uint serverID, const QString &action);

private:
  bool m_available = false;
  QHash<QString, uint> m_serverIDs; // post id -> notification server id, for replacement
  QSet<uint> m_ours;                // every server id we posted, so a click on another app's notification is ignored
};
