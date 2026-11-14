#pragma once
// JSON-RPC 2.0 client for `switch-core serve` (specs/port/architecture.md 2, rpc.md): one JSON object per
// line over the child's stdin and stdout, replies matched by id in any order, `state.changed` topics
// published to QML, per-request timeouts, `$/cancelRequest`, and restart with backoff after a crash.
// Privacy rule: never log params or results; only method, id, duration, and the error kind.
#include <QElapsedTimer>
#include <QHash>
#include <QJSValue>
#include <QJsonObject>
#include <QJsonValue>
#include <QObject>
#include <QProcess>
#include <QQmlPropertyMap>
#include <QStringList>
#include <QTimer>
#include <QVariantMap>
#include <functional>

class QJSEngine;

class HelperClient : public QObject {
  Q_OBJECT
  // "stopped", "starting", "ready", "restarting", "demo"
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)
  Q_PROPERTY(QVariantMap server READ server NOTIFY statusChanged)
  Q_PROPERTY(QQmlPropertyMap *topics READ topics CONSTANT)
public:
  struct Config {
    QString program;            // absolute path of the bundled switch-core, never looked up on PATH
    QString root;               // test root: sets AI_MANAGER_ROOT=<root>/switch and HOME=<root>/home
    QStringList topics{"app", "notices", "accounts"};
    int requestTimeoutMs = 65000; // the helper's own limit is 60 s
    int maxBackoffMs = 30000;
  };
  using Reply = std::function<void(const QJsonValue &result, const QJsonObject &error)>;

  explicit HelperClient(QObject *parent = nullptr);
  ~HelperClient() override;

  void setEngine(QJSEngine *engine) { m_engine = engine; }
  void start(const Config &config);
  void startDemo(const QJsonObject &demo);
  void stop();

  qint64 request(const QString &method, const QJsonObject &params, Reply reply, int timeoutMs = -1);
  void notify(const QString &method, const QJsonObject &params = {});
  void cancel(qint64 id);

  // QML: Helper.call("usage.history", {period: "week"}, function (result, error) { ... })
  Q_INVOKABLE qint64 call(const QString &method, const QVariantMap &params, const QJSValue &callback);
  Q_INVOKABLE void cancelCall(qint64 id) { cancel(id); }
  Q_INVOKABLE bool hasMethod(const QString &method) const;

  QString status() const { return m_status; }
  QVariantMap server() const { return m_server; }
  QQmlPropertyMap *topics() { return &m_topics; }
  qint64 topicRev(const QString &topic) const { return m_revs.value(topic, -1); }
  int restarts() const { return m_restarts; }

signals:
  void statusChanged();
  void topicChanged(const QString &topic);
  void notification(const QString &method, const QJsonObject &params);

private:
  struct Pending {
    QString method;
    Reply reply;
    QTimer *timer = nullptr;
    QElapsedTimer clock;
  };

  void launch();
  void handshake();
  void subscribe(const QStringList &topics);
  void onReadyRead();
  void onFrame(const QByteArray &line);
  void onFinished();
  void finish(qint64 id, const QJsonValue &result, const QJsonObject &error);
  void failAll(const QString &kind, const QString &message);
  void applyTopic(const QString &topic, qint64 rev, const QJsonValue &value);
  void setStatus(const QString &s);
  void write(const QJsonObject &frame);

  Config m_config;
  QProcess *m_proc = nullptr;
  QByteArray m_buf;
  qint64 m_nextId = 1;
  QHash<qint64, Pending> m_pending;
  QHash<QString, qint64> m_revs;
  QQmlPropertyMap m_topics;
  QVariantMap m_server;
  QString m_status = "stopped";
  QJsonObject m_demoReplies;
  QJSEngine *m_engine = nullptr;
  QTimer m_restartTimer;
  int m_backoffMs = 500;
  int m_restarts = 0;
  bool m_stopping = false;
};
