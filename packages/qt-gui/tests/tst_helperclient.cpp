// HelperClient against a fake helper (this binary started as "serve"): handshake, topics, replies out
// of order, timeout, cancel, rev gaps, and crash restart. realHelper runs against a real switch-core.
#include <QCoreApplication>
#include <QTemporaryDir>
#include <QTextStream>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTimer>
#include <QtTest>
#include <iostream>
#include <string>
#include <thread>

#include "helperclient.h"

namespace fake {
int appRev = 0;
int subscribes = 0;

void send(const QJsonObject &o) {
  std::cout << QJsonDocument(o).toJson(QJsonDocument::Compact).toStdString() << std::endl;
}
void reply(const QJsonValue &id, const QJsonValue &result) { send({{"jsonrpc", "2.0"}, {"id", id}, {"result", result}}); }
void changed(bool loaded) {
  send({{"jsonrpc", "2.0"}, {"method", "state.changed"},
        {"params", QJsonObject{{"topic", "app"}, {"rev", appRev}, {"value", QJsonObject{{"hasLoaded", loaded}}}}}});
}

void handle(const QJsonObject &f) {
  const QString m = f.value("method").toString();
  const QJsonValue id = f.value("id");
  if (m == "initialize") reply(id, QJsonObject{{"protocolVersion", 1}, {"topics", QJsonArray{"app", "accounts"}},
                                                {"methods", QJsonArray{"initialize", "slow", "fast"}}});
  else if (m == "state.subscribe") {
    ++subscribes;
    reply(id, QJsonObject{{"app", QJsonObject{{"rev", appRev}, {"value", QJsonObject{{"hasLoaded", appRev > 0}}}}},
                          {"accounts", QJsonObject{{"rev", 0}, {"value", QJsonObject{{"rows", QJsonArray{}}}}}}});
  } else if (m == "initialized") { ++appRev; changed(true); }
  else if (m == "slow") QTimer::singleShot(300, [id] { reply(id, QString("slow")); });
  else if (m == "fast") reply(id, QString("fast"));
  else if (m == "gap") { appRev += 5; changed(true); reply(id, QJsonValue()); }
  else if (m == "stats") reply(id, QJsonObject{{"subscribes", subscribes}});
  else if (m == "crash") std::_Exit(3); // like a crash: no static destructors (exit() can hang on the reader thread)
  else if (m == "$/cancelRequest")
    send({{"jsonrpc", "2.0"}, {"id", f.value("params").toObject().value("id")},
          {"error", QJsonObject{{"code", -32800}, {"message", "The request was cancelled."},
                                {"data", QJsonObject{{"kind", "cancelled"}, {"retryable", false}}}}}});
  // "hang": never answers
}

int run(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  std::thread([] {
    std::string line;
    while (std::getline(std::cin, line)) {
      const QJsonObject f = QJsonDocument::fromJson(QByteArray::fromStdString(line)).object();
      QMetaObject::invokeMethod(qApp, [f] { handle(f); }, Qt::QueuedConnection);
    }
    QMetaObject::invokeMethod(qApp, [] { qApp->quit(); }, Qt::QueuedConnection);
  }).detach();
  return app.exec();
}
} // namespace fake

class TestHelperClient : public QObject {
  Q_OBJECT
  HelperClient *c = nullptr;
  QJsonObject err; // a member: cleanup() fails pending requests after the test function returned

  QJsonObject call(const QString &method, int timeoutMs = -1) {
    QJsonObject out;
    bool done = false;
    c->request(method, {}, [&](const QJsonValue &r, const QJsonObject &e) {
      out = e.isEmpty() ? QJsonObject{{"result", r}} : QJsonObject{{"error", e}};
      done = true;
    }, timeoutMs);
    return QTest::qWaitFor([&] { return done; }, 5000) ? out : QJsonObject{{"error", "no reply"}};
  }

private slots:
  void init() {
    c = new HelperClient;
    HelperClient::Config cfg;
    cfg.program = QCoreApplication::applicationFilePath();
    cfg.topics = {"app", "accounts", "usage"};
    cfg.maxBackoffMs = 200;
    c->start(cfg);
  }
  void cleanup() { delete c; }

  void handshakeAndTopics() {
    QTRY_COMPARE(c->status(), QString("ready"));
    QVERIFY(c->hasMethod("slow"));
    QVERIFY(!c->topics()->contains("usage")); // not offered by the helper
    QTRY_COMPARE(c->topicRev("app"), qint64(1));
    QCOMPARE(c->topics()->value("app").toMap().value("hasLoaded").toBool(), true);
    QVERIFY(c->topics()->value("accounts").toMap().contains("rows"));
  }

  void repliesOutOfOrder() {
    QTRY_COMPARE(c->status(), QString("ready"));
    QStringList order;
    c->request("slow", {}, [&](const QJsonValue &r, const QJsonObject &) { order << r.toString(); });
    c->request("fast", {}, [&](const QJsonValue &r, const QJsonObject &) { order << r.toString(); });
    QTRY_COMPARE(order, QStringList({"fast", "slow"}));
  }

  void timeout() {
    QTRY_COMPARE(c->status(), QString("ready"));
    const QJsonObject r = call("hang", 200);
    QCOMPARE(r.value("error").toObject().value("data").toObject().value("kind").toString(), QString("timeout"));
  }

  void cancel() {
    QTRY_COMPARE(c->status(), QString("ready"));
    err = {};
    const qint64 id = c->request("hang", {}, [&](const QJsonValue &, const QJsonObject &e) { err = e; });
    c->cancel(id);
    QTRY_COMPARE(err.value("code").toInt(), -32800);
  }

  void revGapResubscribes() {
    QTRY_COMPARE(c->status(), QString("ready"));
    QTRY_COMPARE(c->topicRev("app"), qint64(1));
    call("gap");
    QTRY_COMPARE(c->topicRev("app"), qint64(6));
    QTRY_COMPARE(call("stats").value("result").toObject().value("subscribes").toInt(), 2);
  }

  void crashRestarts() {
    QTRY_COMPARE(c->status(), QString("ready"));
    err = {};
    c->request("hang", {}, [&](const QJsonValue &, const QJsonObject &e) { err = e; });
    c->request("crash", {}, nullptr);
    QTRY_COMPARE(err.value("data").toObject().value("kind").toString(), QString("crashed"));
    QTRY_COMPARE(c->restarts(), 1);
    QTRY_COMPARE(c->status(), QString("ready"));
    QCOMPARE(call("fast").value("result").toString(), QString("fast"));
  }

  // Against the real helper: SWITCH_CORE=<switch-core> runs it in a fresh temporary root (never the
  // user's data) and prints the four exchanges as a transcript. Skipped without SWITCH_CORE.
  void realHelper() {
    const QString core = qEnvironmentVariable("SWITCH_CORE");
    if (core.isEmpty()) QSKIP("set SWITCH_CORE to run against a real switch-core");
    QTemporaryDir root;
    QVERIFY(root.isValid());
    HelperClient h;
    HelperClient::Config cfg;
    cfg.program = core;
    cfg.root = root.path();
    h.start(cfg);
    auto show = [](const char *dir, const QString &what, const QJsonValue &v) {
      QByteArray s = QJsonDocument::fromVariant(v.toVariant()).toJson(QJsonDocument::Compact);
      if (v.isString()) s = v.toString().toUtf8();
      if (s.size() > 600) s = s.left(600) + "…";
      QTextStream(stdout) << dir << " " << what << " " << s << Qt::endl;
    };
    QTRY_COMPARE_WITH_TIMEOUT(h.status(), QString("ready"), 20000);
    show("<-", "initialize", QJsonValue::fromVariant(h.server()));
    QVariantMap topics;
    for (const QString &k : h.topics()->keys()) topics[k] = QVariantMap{{"rev", h.topicRev(k)}, {"value", h.topics()->value(k)}};
    show("<-", "state.subscribe", QJsonValue::fromVariant(topics));
    QVERIFY(h.topics()->contains("accounts"));
    for (const auto &[method, params] : {std::pair<QString, QJsonObject>{"accounts.status", {}},
                                         {"usage.history", {{"period", "week"}, {"grouping", "account"}}}}) {
      show("->", method, params);
      QJsonObject out;
      bool done = false;
      h.request(method, params, [&](const QJsonValue &r, const QJsonObject &e) { out = e.isEmpty() ? QJsonObject{{"result", r}} : QJsonObject{{"error", e}}; done = true; });
      QVERIFY(QTest::qWaitFor([&] { return done; }, 60000));
      show("<-", method, out);
      QVERIFY(out.contains("result"));
    }
    h.stop();
  }
};

int main(int argc, char **argv) {
  if (argc > 1 && QByteArray(argv[1]) == "serve") return fake::run(argc, argv);
  QCoreApplication app(argc, argv);
  TestHelperClient t;
  return QTest::qExec(&t, argc, argv);
}

#include "tst_helperclient.moc"
