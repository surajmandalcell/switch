#include "globalshortcut.h"

#include <QHash>
#include <QLoggingCategory>

#ifdef SWITCH_DBUS
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QRandomGenerator>
#endif

Q_LOGGING_CATEGORY(lcShortcut, "switch.shortcut")

QString GlobalShortcut::xdgTrigger(int key, int mods) {
  static const QHash<int, QString> names = {
      {Qt::Key_Return, "Return"}, {Qt::Key_Tab, "Tab"}, {Qt::Key_Space, "space"}, {Qt::Key_Backspace, "BackSpace"},
      {Qt::Key_Escape, "Escape"}, {Qt::Key_Left, "Left"}, {Qt::Key_Right, "Right"}, {Qt::Key_Up, "Up"},
      {Qt::Key_Down, "Down"}, {Qt::Key_Home, "Home"}, {Qt::Key_End, "End"}, {Qt::Key_PageUp, "Prior"},
      {Qt::Key_PageDown, "Next"}, {Qt::Key_Delete, "Delete"}, {Qt::Key_Insert, "Insert"}, {Qt::Key_Minus, "minus"},
      {Qt::Key_Equal, "equal"}, {Qt::Key_BracketLeft, "bracketleft"}, {Qt::Key_BracketRight, "bracketright"},
      {Qt::Key_Semicolon, "semicolon"}, {Qt::Key_Apostrophe, "apostrophe"}, {Qt::Key_Comma, "comma"},
      {Qt::Key_Period, "period"}, {Qt::Key_Slash, "slash"}, {Qt::Key_Backslash, "backslash"}, {Qt::Key_QuoteLeft, "grave"}};
  QString k;
  if (key >= Qt::Key_A && key <= Qt::Key_Z) k = QChar(key).toLower();
  else if (key >= Qt::Key_0 && key <= Qt::Key_9) k = QChar(key);
  else if (key >= Qt::Key_F1 && key <= Qt::Key_F35) k = "F" + QString::number(key - Qt::Key_F1 + 1);
  else k = names.value(key);
  if (k.isEmpty()) return {};
  // Carbon mask as stored by the recorder: Control 4096, Option 2048, Shift 512, Command 256 (Super on Linux).
  QString t;
  if (mods & 4096) t += "CTRL+";
  if (mods & 2048) t += "ALT+";
  if (mods & 512) t += "SHIFT+";
  if (mods & 256) t += "LOGO+";
  return t + k;
}

static QString triggerOf(const QVariant &combo) {
  const QVariantMap c = combo.toMap();
  if (c.isEmpty() || !(c.value("modifiers").toInt() & (4096 | 2048 | 256))) return {};   // shell.md 5.1 validity rule
  return GlobalShortcut::xdgTrigger(c.value("key").toInt(), c.value("modifiers").toInt());
}

#ifndef SWITCH_DBUS
// shortcut: no registration off Linux (Windows wants RegisterHotKey, shell.md 5.2); the row stays off there.
GlobalShortcut::GlobalShortcut(QObject *parent) : QObject(parent) {}
void GlobalShortcut::apply(const QVariant &combo) { m_trigger = triggerOf(combo); }
#else

// org.freedesktop.portal.GlobalShortcuts (version 1): CreateSession, BindShortcuts, Activated.
static const char *kService = "org.freedesktop.portal.Desktop";
static const char *kPath = "/org/freedesktop/portal/desktop";
static const char *kIface = "org.freedesktop.portal.GlobalShortcuts";
static const char *kId = "menu";
static const char *kAppId = "com.mandalsuraj.Switch";

struct PortalShortcut {
  QString id;
  QVariantMap props;
};
Q_DECLARE_METATYPE(PortalShortcut)
QDBusArgument &operator<<(QDBusArgument &a, const PortalShortcut &s) {
  a.beginStructure();
  a << s.id << s.props;
  a.endStructure();
  return a;
}
const QDBusArgument &operator>>(const QDBusArgument &a, PortalShortcut &s) {
  a.beginStructure();
  a >> s.id >> s.props;
  a.endStructure();
  return a;
}

// A private bus connection: the portal fixes a connection's app id at its first portal call, and Qt's own
// connection has already read the Settings portal by then (Register then fails with "already associated").
static const char *kConn = "switch-shortcuts";
static QDBusConnection bus() { return QDBusConnection(kConn); }

static QString token() { return "switch" + QString::number(QRandomGenerator::global()->generate()); }

GlobalShortcut::GlobalShortcut(QObject *parent) : QObject(parent) {
  qDBusRegisterMetaType<PortalShortcut>();
  qDBusRegisterMetaType<QList<PortalShortcut>>();
  auto bus = QDBusConnection::connectToBus(QDBusConnection::SessionBus, kConn);
  if (!bus.isConnected()) return;
  bus.connect(kService, kPath, kIface, "Activated", this, SLOT(onActivated(QDBusMessage)));
  // A host (non-sandboxed) app names its app id before any other portal call; GlobalShortcuts refuses a host app
  // without one ("An app id is required"). The id must be reverse-DNS and match the installed <id>.desktop file.
  auto reg = QDBusMessage::createMethodCall(kService, kPath, "org.freedesktop.host.portal.Registry", "Register");
  reg.setArguments({QString(kAppId), QVariantMap()});
  auto *w = new QDBusPendingCallWatcher(bus.asyncCall(reg), this);
  connect(w, &QDBusPendingCallWatcher::finished, this, [this, bus](QDBusPendingCallWatcher *w) {
    w->deleteLater();
    if (w->isError()) qCInfo(lcShortcut) << "app id not registered:" << w->error().message();
    auto get = QDBusMessage::createMethodCall(kService, kPath, "org.freedesktop.DBus.Properties", "Get");
    get.setArguments({QString(kIface), QString("version")});
    auto *v = new QDBusPendingCallWatcher(bus.asyncCall(get), this);
    connect(v, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *v) {
      v->deleteLater();
      const QDBusMessage r = v->reply();
      const uint version = r.type() == QDBusMessage::ReplyMessage && !r.arguments().isEmpty()
                               ? r.arguments().first().value<QDBusVariant>().variant().toUInt() : 0;
      qCInfo(lcShortcut) << "portal GlobalShortcuts version" << version;
      if (version < 1) return;
      m_available = true;
      emit availableChanged();
      if (!m_trigger.isEmpty()) bind();
    });
  });
}

void GlobalShortcut::apply(const QVariant &combo) {
  const QString trigger = triggerOf(combo);
  if (trigger == m_trigger) return;
  m_trigger = trigger;
  ++m_generation;
  closeSession();
  if (combo.toMap().isEmpty()) return;
  if (trigger.isEmpty()) { emit refused(); return; }   // a key with no XDG name cannot be bound
  if (m_available) bind();
}

void GlobalShortcut::closeSession() {
  if (m_session.isEmpty()) return;
  bus().asyncCall(QDBusMessage::createMethodCall(kService, m_session, "org.freedesktop.portal.Session", "Close"));
  m_session.clear();
}

// Portal calls answer with a Request object; its Response signal carries the result. The signal is
// subscribed before the call, on the path the portal derives from our bus name and handle_token.
QString GlobalShortcut::request(const QString &method, QVariantList args,
                                std::function<void(uint, const QVariantMap &)> done) {
  auto bus = ::bus();
  const QString tok = token();
  const QString path = QString("/org/freedesktop/portal/desktop/request/%1/%2")
                           .arg(bus.baseService().mid(1).replace('.', '_'), tok);
  bus.connect(kService, path, "org.freedesktop.portal.Request", "Response", this, SLOT(onResponse(QDBusMessage)));
  m_requests.insert(path, std::move(done));
  QVariantMap opts = args.takeLast().toMap();
  opts.insert("handle_token", tok);
  args.append(opts);
  auto call = QDBusMessage::createMethodCall(kService, kPath, kIface, method);
  call.setArguments(args);
  auto *w = new QDBusPendingCallWatcher(bus.asyncCall(call), this);
  connect(w, &QDBusPendingCallWatcher::finished, this, [this, path, method](QDBusPendingCallWatcher *w) {
    w->deleteLater();
    if (!w->isError()) return;
    qCWarning(lcShortcut) << method << "failed:" << w->error().name();
    if (auto done = m_requests.take(path)) done(2, {});
  });
  return path;
}

void GlobalShortcut::onResponse(const QDBusMessage &msg) {
  bus().disconnect(kService, msg.path(), "org.freedesktop.portal.Request", "Response", this,
                                           SLOT(onResponse(QDBusMessage)));
  auto done = m_requests.take(msg.path());
  if (!done || msg.arguments().size() < 2) return;
  done(msg.arguments().at(0).toUInt(), qdbus_cast<QVariantMap>(msg.arguments().at(1)));
}

void GlobalShortcut::bind() {
  const int gen = m_generation;
  const QString tok = token();
  request("CreateSession", {QVariantMap{{"session_handle_token", tok}}}, [this, gen](uint code, const QVariantMap &r) {
    const QVariant h = r.value("session_handle");
    const QString session = h.userType() == qMetaTypeId<QDBusObjectPath>() ? h.value<QDBusObjectPath>().path() : h.toString();
    if (gen != m_generation) {   // the combo changed while the session was being made
      if (!session.isEmpty()) {
        bus().asyncCall(
            QDBusMessage::createMethodCall(kService, session, "org.freedesktop.portal.Session", "Close"));
      }
      return;
    }
    if (code != 0 || session.isEmpty()) {
      qCWarning(lcShortcut) << "CreateSession refused, code" << code;
      emit refused();
      return;
    }
    m_session = session;
    const QList<PortalShortcut> list{{kId, {{"description", QString("Open or close the menu popover")},
                                            {"preferred_trigger", m_trigger}}}};
    // No exported Wayland window handle: the portal accepts "" as "no parent".
    request("BindShortcuts", {QVariant::fromValue(QDBusObjectPath(session)), QVariant::fromValue(list), QString(),
                              QVariantMap()},
            [this, gen](uint code, const QVariantMap &r) {
              if (gen != m_generation) return;
              if (code != 0) {
                qCWarning(lcShortcut) << "BindShortcuts refused, code" << code;
                closeSession();
                emit refused();
                return;
              }
              const auto bound = qdbus_cast<QList<PortalShortcut>>(r.value("shortcuts"));
              qCInfo(lcShortcut) << "bound" << m_trigger << "as"
                                 << (bound.isEmpty() ? QString() : bound.first().props.value("trigger_description").toString());
            });
  });
}

void GlobalShortcut::onActivated(const QDBusMessage &msg) {
  const QVariantList a = msg.arguments();
  if (a.size() < 2 || a.at(0).value<QDBusObjectPath>().path() != m_session || a.at(1).toString() != kId) return;
  qCInfo(lcShortcut) << "activated";
  emit activated();
}
#endif
