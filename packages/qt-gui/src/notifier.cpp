#include "notifier.h"

#include <QCoreApplication>
#include <QVariantMap>
#ifdef SWITCH_DBUS
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>

namespace {
const char *kService = "org.freedesktop.Notifications";
const char *kPath = "/org/freedesktop/Notifications";
const char *kInterface = "org.freedesktop.Notifications";
} // namespace
#endif

Notifier::Notifier(QObject *parent) : QObject(parent) {
#ifdef SWITCH_DBUS
  QDBusConnection bus = QDBusConnection::sessionBus();
  m_available = bus.isConnected();
  if (m_available)
    bus.connect(kService, kPath, kInterface, "ActionInvoked", this, SLOT(onActionInvoked(uint, QString)));
#endif
}

void Notifier::post(const QString &id, const QString &title, const QString &subtitle, const QString &body,
                    bool alert) {
  const QString text = subtitle.isEmpty() ? body : body.isEmpty() ? subtitle : subtitle + "\n" + body;
#ifdef SWITCH_DBUS
  if (m_available) {
    QVariantMap hints;
    if (alert) hints.insert("sound-name", "message-new-instant");
    else hints.insert("suppress-sound", true);
    QDBusMessage call = QDBusMessage::createMethodCall(kService, kPath, kInterface, "Notify");
    call << QCoreApplication::applicationName() << m_serverIDs.value(id, 0u) << QString("switch") << title << text
         << QStringList{"default", "Open Switch"} << hints << -1;
    auto *watch = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(call), this);
    connect(watch, &QDBusPendingCallWatcher::finished, this, [this, id](QDBusPendingCallWatcher *w) {
      const QDBusPendingReply<uint> reply = *w;
      if (!reply.isError()) {
        m_ours.insert(reply.value());
        if (!id.isEmpty()) m_serverIDs.insert(id, reply.value());
      }
      w->deleteLater();
    });
    return;
  }
#endif
  // shortcut: Windows and a Linux session without a notification service use the tray balloon (no replacement,
  // no sound choice); build the WinRT toast of settings.md 8.2 when a Windows machine can test it.
  Q_UNUSED(id) Q_UNUSED(alert)
  emit fallback(title, text);
}

void Notifier::onActionInvoked(uint serverID, const QString &action) {
  if (action == "default" && m_ours.contains(serverID)) emit activated();
}
