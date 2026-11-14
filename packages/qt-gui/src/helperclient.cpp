#include "helperclient.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJSEngine>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocale>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(lcHelper, "switch.helper", QtWarningMsg)

namespace {
constexpr qsizetype kMaxFrame = 16 * 1024 * 1024; // rpc.md: frames over 16 MiB are refused

QJsonObject makeError(int code, const QString &kind, const QString &message, bool retryable) {
  return QJsonObject{{"code", code}, {"message", message},
                     {"data", QJsonObject{{"kind", kind}, {"retryable", retryable}}}};
}
} // namespace

HelperClient::HelperClient(QObject *parent) : QObject(parent) {
  m_restartTimer.setSingleShot(true);
  connect(&m_restartTimer, &QTimer::timeout, this, &HelperClient::launch);
}

HelperClient::~HelperClient() { stop(); }

void HelperClient::setStatus(const QString &s) {
  if (s == m_status) return;
  m_status = s;
  emit statusChanged();
}

void HelperClient::start(const Config &config) {
  m_config = config;
  m_stopping = false;
  m_backoffMs = 500;
  if (!QFileInfo(config.program).isAbsolute()) {
    qCWarning(lcHelper) << "helper path must be absolute; not started";
    return;
  }
  launch();
}

void HelperClient::launch() {
  delete m_proc;
  m_buf.clear();
  m_revs.clear(); // a new helper counts revs from 0 again
  m_stopping = false;
  m_proc = new QProcess(this);
  m_proc->setProgram(m_config.program);
  m_proc->setArguments({"serve"});
  if (!m_config.root.isEmpty()) {
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    QDir().mkpath(m_config.root + "/switch");
    QDir().mkpath(m_config.root + "/home");
    env.insert("AI_MANAGER_ROOT", m_config.root + "/switch");
    env.insert("HOME", m_config.root + "/home");
    // An inherited XDG_* path would lead the helper back into the real profile.
    for (const char *k : {"XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"}) env.remove(k);
    // AI_MANAGER_ROOT is what `serve --root` sets; the variable also works with helpers older than --root.
    m_proc->setProcessEnvironment(env);
  }
  connect(m_proc, &QProcess::readyReadStandardOutput, this, &HelperClient::onReadyRead);
  // stderr carries one line per request without params (rpc.md); keep it out of our log by default.
  connect(m_proc, &QProcess::readyReadStandardError, this, [this] {
    const QByteArray err = m_proc->readAllStandardError();
    qCDebug(lcHelper).noquote() << "helper stderr:" << err.size() << "bytes";
  });
  connect(m_proc, &QProcess::finished, this, &HelperClient::onFinished);
  connect(m_proc, &QProcess::errorOccurred, this, [this](QProcess::ProcessError e) {
    if (e == QProcess::FailedToStart) onFinished();
  });
  setStatus(m_restarts ? "restarting" : "starting");
  m_proc->start(QIODevice::ReadWrite);
  handshake();
}

void HelperClient::handshake() {
  const QJsonObject params{
      {"protocolVersion", 1},
      {"client", QJsonObject{{"name", "switch-qt"}, {"version", QCoreApplication::applicationVersion()}}},
      {"locale", QLocale().name()},
      {"hourCycle", "auto"},
#ifdef Q_OS_WIN
      {"platform", "windows"},
#else
      {"platform", "linux"},
#endif
      {"capabilities", QJsonObject{{"notifications", true}, {"tray", true}, {"globalShortcut", false}}}};
  request("initialize", params, [this](const QJsonValue &result, const QJsonObject &error) {
    if (!error.isEmpty()) return; // a crash already scheduled the restart
    m_server = result.toObject().toVariantMap();
    m_backoffMs = 500;
    QStringList wanted;
    const QVariantList offered = m_server.value("topics").toList();
    for (const QString &t : m_config.topics)
      if (offered.contains(t)) wanted << t;
    subscribe(wanted);
  });
}

void HelperClient::subscribe(const QStringList &topics) {
  request("state.subscribe", QJsonObject{{"topics", QJsonArray::fromStringList(topics)}},
          [this](const QJsonValue &result, const QJsonObject &error) {
            if (!error.isEmpty()) return;
            const QJsonObject snap = result.toObject();
            for (auto it = snap.begin(); it != snap.end(); ++it) {
              const QJsonObject t = it.value().toObject();
              applyTopic(it.key(), t.value("rev").toInteger(), t.value("value"));
            }
            if (m_status != "ready") {
              notify("initialized");
              setStatus("ready");
            }
          });
}

void HelperClient::startDemo(const QJsonObject &demo) {
  stop();
  const QJsonObject topics = demo.value("topics").toObject();
  for (auto it = topics.begin(); it != topics.end(); ++it) applyTopic(it.key(), 0, it.value());
  m_demoReplies = demo.value("replies").toObject();
  m_server = QVariantMap{{"methods", QVariantList()}, {"topics", QVariant(topics.keys())}};
  setStatus("demo");
}

void HelperClient::stop() {
  m_stopping = true;
  m_restartTimer.stop();
  if (m_proc) {
    m_proc->disconnect(this);
    if (m_proc->state() != QProcess::NotRunning) {
      m_proc->closeWriteChannel(); // the helper exits when stdin closes
      if (!m_proc->waitForFinished(2000)) m_proc->kill();
      m_proc->waitForFinished(1000);
    }
    delete m_proc;
    m_proc = nullptr;
  }
  failAll("cancelled", "Switch stopped the helper.");
  if (m_status != "demo") setStatus("stopped");
}

void HelperClient::write(const QJsonObject &frame) {
  if (!m_proc || m_proc->state() == QProcess::NotRunning) return;
  m_proc->write(QJsonDocument(frame).toJson(QJsonDocument::Compact) + '\n');
}

qint64 HelperClient::request(const QString &method, const QJsonObject &params, Reply reply, int timeoutMs) {
  const qint64 id = m_nextId++;
  if (m_status == "demo") {
    // Demo mode answers from demo.json, a turn later, like a real reply.
    QTimer::singleShot(0, this, [reply, method, this] {
      if (m_demoReplies.contains(method)) reply(m_demoReplies.value(method), {});
      else reply({}, makeError(-32005, "unsupported", "Not available in demo mode.", false));
    });
    return id;
  }
  Pending p;
  p.method = method;
  p.reply = std::move(reply);
  p.clock.start();
  p.timer = new QTimer(this);
  p.timer->setSingleShot(true);
  connect(p.timer, &QTimer::timeout, this, [this, id] {
    write(QJsonObject{{"jsonrpc", "2.0"}, {"method", "$/cancelRequest"}, {"params", QJsonObject{{"id", id}}}});
    finish(id, {}, makeError(-32007, "timeout", "Switch did not answer in time.", true));
  });
  p.timer->start(timeoutMs > 0 ? timeoutMs : m_config.requestTimeoutMs);
  m_pending.insert(id, std::move(p));
  QJsonObject frame{{"jsonrpc", "2.0"}, {"id", id}, {"method", method}};
  if (!params.isEmpty()) frame.insert("params", params);
  if (!m_proc || m_proc->state() == QProcess::NotRunning)
    QTimer::singleShot(0, this, [this, id] { finish(id, {}, makeError(-32002, "unavailable", "The helper is not running.", true)); });
  else write(frame);
  return id;
}

void HelperClient::notify(const QString &method, const QJsonObject &params) {
  QJsonObject frame{{"jsonrpc", "2.0"}, {"method", method}};
  if (!params.isEmpty()) frame.insert("params", params);
  write(frame);
}

void HelperClient::cancel(qint64 id) {
  if (!m_pending.contains(id)) return;
  // The helper answers the request itself with -32800.
  notify("$/cancelRequest", QJsonObject{{"id", id}});
}

qint64 HelperClient::call(const QString &method, const QVariantMap &params, const QJSValue &callback) {
  return request(method, QJsonObject::fromVariantMap(params), [this, callback](const QJsonValue &result, const QJsonObject &error) {
    if (!callback.isCallable() || !m_engine) return;
    QJSValue cb = callback;
    cb.call({m_engine->toScriptValue(result.toVariant()),
             error.isEmpty() ? QJSValue(QJSValue::NullValue) : m_engine->toScriptValue(error.toVariantMap())});
  });
}

bool HelperClient::hasMethod(const QString &method) const {
  return m_server.value("methods").toList().contains(method);
}

void HelperClient::onReadyRead() {
  m_buf += m_proc->readAllStandardOutput();
  qsizetype nl;
  while ((nl = m_buf.indexOf('\n')) >= 0) {
    const QByteArray line = m_buf.left(nl);
    m_buf.remove(0, nl + 1);
    if (!line.trimmed().isEmpty()) onFrame(line);
  }
  if (m_buf.size() > kMaxFrame) {
    qCWarning(lcHelper) << "helper frame over 16 MiB dropped";
    m_buf.clear();
  }
}

void HelperClient::onFrame(const QByteArray &line) {
  QJsonParseError pe;
  const QJsonDocument doc = QJsonDocument::fromJson(line, &pe);
  if (!doc.isObject()) {
    qCWarning(lcHelper) << "helper sent a frame that is not a JSON object";
    return;
  }
  const QJsonObject f = doc.object();
  if (f.contains("id") && !f.contains("method")) {
    finish(f.value("id").toInteger(-1), f.value("result"), f.value("error").toObject());
    return;
  }
  const QString method = f.value("method").toString();
  const QJsonObject params = f.value("params").toObject();
  if (method == "state.changed") {
    const QString topic = params.value("topic").toString();
    const qint64 rev = params.value("rev").toInteger();
    const qint64 known = m_revs.value(topic, -1);
    applyTopic(topic, rev, params.value("value"));
    if (known >= 0 && rev > known + 1) subscribe({topic}); // a gap means a lost frame
    return;
  }
  emit notification(method, params);
}

void HelperClient::applyTopic(const QString &topic, qint64 rev, const QJsonValue &value) {
  if (m_revs.contains(topic) && rev <= m_revs.value(topic)) return; // a change may beat the subscribe reply
  m_revs.insert(topic, rev);
  m_topics.insert(topic, value.toVariant());
  emit topicChanged(topic);
}

void HelperClient::finish(qint64 id, const QJsonValue &result, const QJsonObject &error) {
  auto it = m_pending.find(id);
  if (it == m_pending.end()) return; // already timed out, or unknown
  Pending p = std::move(it.value());
  m_pending.erase(it);
  p.timer->deleteLater();
  qCInfo(lcHelper).noquote() << "rpc" << p.method << "id=" << id << p.clock.elapsed() << "ms"
                             << (error.isEmpty() ? QString("ok") : error.value("data").toObject().value("kind").toString());
  if (p.reply) p.reply(result, error);
}

void HelperClient::failAll(const QString &kind, const QString &message) {
  const QList<qint64> ids = m_pending.keys();
  for (qint64 id : ids) finish(id, {}, makeError(kind == "cancelled" ? -32800 : -32002, kind, message, kind != "cancelled"));
}

void HelperClient::onFinished() {
  if (m_stopping || m_restartTimer.isActive()) return;
  failAll("crashed", "The Switch helper stopped. Restarting it.");
  ++m_restarts;
  setStatus("restarting");
  qCWarning(lcHelper) << "helper exited; restart in" << m_backoffMs << "ms";
  m_restartTimer.start(m_backoffMs);
  m_backoffMs = std::min(m_backoffMs * 2, m_config.maxBackoffMs);
}
