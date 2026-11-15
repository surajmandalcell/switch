#include "globalshortcut.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QLoggingCategory>
#include <QSaveFile>
#include <QStandardPaths>

#ifdef SWITCH_DBUS
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#include <QRandomGenerator>
#endif
#ifdef SWITCH_XCB
#include <QSocketNotifier>
#include <cstdlib>
#include <xcb/xcb.h>
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

// Qt key <-> Mac virtual key code (Carbon kVK_*, ANSI layout), so settings.json keeps the settings.md format.
static const std::pair<int, int> kMacKeys[] = {
    {Qt::Key_A, 0x00}, {Qt::Key_S, 0x01}, {Qt::Key_D, 0x02}, {Qt::Key_F, 0x03}, {Qt::Key_H, 0x04},
    {Qt::Key_G, 0x05}, {Qt::Key_Z, 0x06}, {Qt::Key_X, 0x07}, {Qt::Key_C, 0x08}, {Qt::Key_V, 0x09},
    {Qt::Key_B, 0x0B}, {Qt::Key_Q, 0x0C}, {Qt::Key_W, 0x0D}, {Qt::Key_E, 0x0E}, {Qt::Key_R, 0x0F},
    {Qt::Key_Y, 0x10}, {Qt::Key_T, 0x11}, {Qt::Key_1, 0x12}, {Qt::Key_2, 0x13}, {Qt::Key_3, 0x14},
    {Qt::Key_4, 0x15}, {Qt::Key_6, 0x16}, {Qt::Key_5, 0x17}, {Qt::Key_Equal, 0x18}, {Qt::Key_9, 0x19},
    {Qt::Key_7, 0x1A}, {Qt::Key_Minus, 0x1B}, {Qt::Key_8, 0x1C}, {Qt::Key_0, 0x1D}, {Qt::Key_BracketRight, 0x1E},
    {Qt::Key_O, 0x1F}, {Qt::Key_U, 0x20}, {Qt::Key_BracketLeft, 0x21}, {Qt::Key_I, 0x22}, {Qt::Key_P, 0x23},
    {Qt::Key_Return, 0x24}, {Qt::Key_L, 0x25}, {Qt::Key_J, 0x26}, {Qt::Key_Apostrophe, 0x27}, {Qt::Key_K, 0x28},
    {Qt::Key_Semicolon, 0x29}, {Qt::Key_Backslash, 0x2A}, {Qt::Key_Comma, 0x2B}, {Qt::Key_Slash, 0x2C},
    {Qt::Key_N, 0x2D}, {Qt::Key_M, 0x2E}, {Qt::Key_Period, 0x2F}, {Qt::Key_Tab, 0x30}, {Qt::Key_Space, 0x31},
    {Qt::Key_QuoteLeft, 0x32}, {Qt::Key_Backspace, 0x33}, {Qt::Key_Escape, 0x35},
    {Qt::Key_F1, 0x7A}, {Qt::Key_F2, 0x78}, {Qt::Key_F3, 0x63}, {Qt::Key_F4, 0x76}, {Qt::Key_F5, 0x60},
    {Qt::Key_F6, 0x61}, {Qt::Key_F7, 0x62}, {Qt::Key_F8, 0x64}, {Qt::Key_F9, 0x65}, {Qt::Key_F10, 0x6D},
    {Qt::Key_F11, 0x67}, {Qt::Key_F12, 0x6F}, {Qt::Key_F13, 0x69}, {Qt::Key_F14, 0x6B}, {Qt::Key_F15, 0x71},
    {Qt::Key_F16, 0x6A}, {Qt::Key_F17, 0x40}, {Qt::Key_F18, 0x4F}, {Qt::Key_F19, 0x50}, {Qt::Key_F20, 0x5A},
    {Qt::Key_Insert, 0x72}, {Qt::Key_Home, 0x73}, {Qt::Key_PageUp, 0x74}, {Qt::Key_Delete, 0x75},
    {Qt::Key_End, 0x77}, {Qt::Key_PageDown, 0x79}, {Qt::Key_Left, 0x7B}, {Qt::Key_Right, 0x7C},
    {Qt::Key_Down, 0x7D}, {Qt::Key_Up, 0x7E}};   // Insert sits where the Mac has Help (kVK_Help)

int GlobalShortcut::macKeyCode(int key) {
  for (auto [q, m] : kMacKeys)
    if (q == key) return m;
  return -1;
}

int GlobalShortcut::qtKey(int code) {
  for (auto [q, m] : kMacKeys)
    if (m == code) return q;
  return 0;
}

uint GlobalShortcut::keysym(int key) {
  if (key >= Qt::Key_A && key <= Qt::Key_Z) return key + 0x20;   // lower-case Latin keysyms
  if (key >= 0x20 && key < 0x7f) return key;                     // digits and ASCII punctuation
  if (key >= Qt::Key_F1 && key <= Qt::Key_F35) return 0xffbe + (key - Qt::Key_F1);
  static const QHash<int, uint> syms = {
      {Qt::Key_Return, 0xff0d}, {Qt::Key_Tab, 0xff09}, {Qt::Key_Backspace, 0xff08}, {Qt::Key_Escape, 0xff1b},
      {Qt::Key_Left, 0xff51}, {Qt::Key_Up, 0xff52}, {Qt::Key_Right, 0xff53}, {Qt::Key_Down, 0xff54},
      {Qt::Key_Home, 0xff50}, {Qt::Key_End, 0xff57}, {Qt::Key_PageUp, 0xff55}, {Qt::Key_PageDown, 0xff56},
      {Qt::Key_Delete, 0xffff}, {Qt::Key_Insert, 0xff63}};
  return syms.value(key);
}

// The stored combo's Qt key, or 0 for none: null, an unknown key code, or no Ctrl, Alt or Super (shell.md 5.1;
// an invalid stored value loads as none).
static int keyOf(const QVariant &combo) {
  const QVariantMap c = combo.toMap();
  if (c.isEmpty() || !(c.value("modifiers").toInt() & (4096 | 2048 | 256))) return 0;
  return GlobalShortcut::qtKey(c.value("keyCode", -1).toInt());
}

// The app id: the Wayland app_id (main.cpp), the portal registration, and the desktop entry name.
static const char *kAppId = "com.mandalsuraj.Switch";

QByteArray GlobalShortcut::desktopExec(const QString &path) {
  // Quote, backslash-escape " ` $ \ inside the quotes, escape each backslash again for the string value,
  // and double % (a field code otherwise).
  QString q;
  for (QChar c : path) {
    if (c == '"' || c == '`' || c == '$' || c == '\\') q += '\\';
    q += c == '%' ? QString("%%") : QString(c);
  }
  return "\"" + q.replace("\\", "\\\\").toUtf8() + "\"";
}

void GlobalShortcut::writeAppImageEntry() {
  const QString image = qEnvironmentVariable("APPIMAGE");
  if (image.isEmpty()) return;
  QFile shipped(qEnvironmentVariable("APPDIR") + "/" + kAppId + ".desktop");
  const QByteArray in = shipped.open(QIODevice::ReadOnly) ? shipped.readAll()
                                                          : QByteArray("[Desktop Entry]\nType=Application\nName=Switch\nExec=\n");
  QByteArrayList out;
  for (const QByteArray &line : in.split('\n')) {
    if (line.startsWith("TryExec=")) continue;
    out << (line.startsWith("Exec=") ? "Exec=" + desktopExec(image) : line);
  }
  const QByteArray body = out.join('\n');
  const QString path = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/applications/" + kAppId + ".desktop";
  QFile current(path);
  if (current.open(QIODevice::ReadOnly) && current.readAll() == body) return;
  current.close();
  QDir().mkpath(QFileInfo(path).absolutePath());
  QSaveFile f(path);
  if (f.open(QIODevice::WriteOnly) && f.write(body) == body.size() && f.commit()) qCInfo(lcShortcut) << "wrote the AppImage desktop entry";
  else qCWarning(lcShortcut) << "AppImage desktop entry not written:" << f.errorString();
}

#ifndef SWITCH_DBUS
// shortcut: no registration off Linux (Windows wants RegisterHotKey, shell.md 5.2); the row stays off there.
GlobalShortcut::GlobalShortcut(QObject *parent) : QObject(parent) {}
GlobalShortcut::~GlobalShortcut() = default;
void GlobalShortcut::apply(const QVariant &) {}
#else

// org.freedesktop.portal.GlobalShortcuts (version 1): CreateSession, BindShortcuts, Activated.
static const char *kService = "org.freedesktop.portal.Desktop";
static const char *kPath = "/org/freedesktop/portal/desktop";
static const char *kIface = "org.freedesktop.portal.GlobalShortcuts";
static const char *kId = "menu";

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
  if (!bus.isConnected()) {
#ifdef SWITCH_XCB
    startX11();
#endif
    return;
  }
  bus.connect(kService, kPath, kIface, "Activated", this, SLOT(onActivated(QDBusMessage)));
  writeAppImageEntry();   // the portal looks the app id up in the desktop entries at Register
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
      if (version < 1) {   // settings.md 8.4: no portal, so fall back to an X11 grab (X11 or XWayland)
#ifdef SWITCH_XCB
        startX11();
#endif
        return;
      }
      m_portal = m_available = true;
      emit availableChanged();
      if (!m_trigger.isEmpty()) bind();
    });
  });
}

GlobalShortcut::~GlobalShortcut() {
#ifdef SWITCH_XCB
  ungrabX11();
  if (m_xcb) xcb_disconnect(m_xcb);
#endif
}

void GlobalShortcut::apply(const QVariant &combo) {
  const int key = keyOf(combo);
  const int mods = key ? combo.toMap().value("modifiers").toInt() : 0;
  const QString trigger = key ? xdgTrigger(key, mods) : QString();   // every key in kMacKeys has an XDG name
  if (trigger == m_trigger) return;
  m_trigger = trigger;
  m_key = key;
  m_mods = mods;
  ++m_generation;
  closeSession();
#ifdef SWITCH_XCB
  ungrabX11();
  if (m_xcb && key && !grabX11()) { emit refused(); return; }
#endif
  if (m_portal && key) bind();
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

#ifdef SWITCH_XCB
// settings.md 8.4 Linux X11: a key grab on the root window over our own connection to $DISPLAY (also XWayland),
// with every NumLock and CapsLock variant; BadAccess (another client holds it) = refusal.
static const uint16_t kLockVariants[] = {0, XCB_MOD_MASK_2, XCB_MOD_MASK_LOCK, XCB_MOD_MASK_2 | XCB_MOD_MASK_LOCK};
static const uint16_t kXMods = XCB_MOD_MASK_CONTROL | XCB_MOD_MASK_1 | XCB_MOD_MASK_SHIFT | XCB_MOD_MASK_4;

void GlobalShortcut::startX11() {
  if (m_xcb || qEnvironmentVariableIsEmpty("DISPLAY")) return;
  m_xcb = xcb_connect(nullptr, nullptr);
  if (xcb_connection_has_error(m_xcb)) {
    xcb_disconnect(m_xcb);
    m_xcb = nullptr;
    return;
  }
  m_root = xcb_setup_roots_iterator(xcb_get_setup(m_xcb)).data->root;
  auto *n = new QSocketNotifier(xcb_get_file_descriptor(m_xcb), QSocketNotifier::Read, this);
  connect(n, &QSocketNotifier::activated, this, &GlobalShortcut::onXcbEvent);
  qCInfo(lcShortcut) << "using the X11 key grab";
  m_available = true;
  emit availableChanged();
  if (m_key && !grabX11()) emit refused();
}

bool GlobalShortcut::grabX11() {
  const uint sym = keysym(m_key);
  const xcb_setup_t *s = xcb_get_setup(m_xcb);
  const int count = s->max_keycode - s->min_keycode + 1;
  xcb_get_keyboard_mapping_reply_t *map =
      xcb_get_keyboard_mapping_reply(m_xcb, xcb_get_keyboard_mapping(m_xcb, s->min_keycode, count), nullptr);
  uint keycode = 0;
  if (map) {
    const xcb_keysym_t *syms = xcb_get_keyboard_mapping_keysyms(map);
    for (int i = 0; i < count * map->keysyms_per_keycode && !keycode; ++i)
      if (syms[i] == sym) keycode = s->min_keycode + i / map->keysyms_per_keycode;
    free(map);
  }
  if (!sym || !keycode) {
    qCWarning(lcShortcut) << "X11: no key code for" << m_trigger;
    return false;
  }
  m_xmods = ((m_mods & 4096) ? XCB_MOD_MASK_CONTROL : 0) | ((m_mods & 2048) ? XCB_MOD_MASK_1 : 0) |
            ((m_mods & 512) ? XCB_MOD_MASK_SHIFT : 0) | ((m_mods & 256) ? XCB_MOD_MASK_4 : 0);
  m_keycode = keycode;
  bool ok = true;
  for (uint16_t v : kLockVariants) {
    xcb_generic_error_t *e = xcb_request_check(
        m_xcb, xcb_grab_key_checked(m_xcb, 1, m_root, m_xmods | v, keycode, XCB_GRAB_MODE_ASYNC, XCB_GRAB_MODE_ASYNC));
    if (e) ok = false;
    free(e);
  }
  if (!ok) {
    qCWarning(lcShortcut) << "X11: grab refused for" << m_trigger;
    ungrabX11();
    return false;
  }
  qCInfo(lcShortcut) << "X11: grabbed" << m_trigger;
  return true;
}

void GlobalShortcut::ungrabX11() {
  if (!m_xcb || !m_keycode) return;
  for (uint16_t v : kLockVariants) xcb_ungrab_key(m_xcb, m_keycode, m_root, m_xmods | v);
  xcb_flush(m_xcb);
  m_keycode = 0;
}

void GlobalShortcut::onXcbEvent() {
  while (xcb_generic_event_t *ev = xcb_poll_for_event(m_xcb)) {
    const uint8_t type = ev->response_type & ~0x80;
    if (type == XCB_KEY_PRESS || type == XCB_KEY_RELEASE) {
      auto *k = reinterpret_cast<xcb_key_press_event_t *>(ev);
      if (m_keycode && k->detail == m_keycode && (k->state & kXMods) == m_xmods) {
        if (type == XCB_KEY_RELEASE) m_lastRelease = k->time;
        else if (k->time != m_lastRelease) {   // not an auto-repeat
          qCInfo(lcShortcut) << "activated";
          emit activated();
        }
      }
    }
    free(ev);
  }
}
#endif
#endif
