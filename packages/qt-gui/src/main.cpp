#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QJsonDocument>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSGRendererInterface>

#include "appstate.h"
#include "helperclient.h"
#include "tray.h"
#ifdef SWITCH_HARNESS
#include "harness.h"
#include <qpa/qwindowsysteminterface.h>
#endif

int main(int argc, char *argv[]) {
  // One logical DPI everywhere, so a QML pointSize of px * 0.75 is exactly px logical pixels.
  qputenv("QT_FONT_DPI", "96");
  if (!qEnvironmentVariableIsSet("QSG_RHI_BACKEND")) QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);

  QApplication app(argc, argv);
  app.setApplicationName("Switch");
  app.setApplicationVersion("0.1.0");

  const int fontId = QFontDatabase::addApplicationFont(":/qt/qml/SwitchUI/fonts/InterVariable.ttf");
  const QStringList fams = QFontDatabase::applicationFontFamilies(fontId);
  AppState state(app.arguments(), fams.isEmpty() ? QString("Sans") : fams.first());
  app.installEventFilter(&state);

  HelperClient helper;
  if (state.flag("demo")) {
    QFile f(":/qt/qml/SwitchUI/assets/demo.json");
    if (!f.open(QIODevice::ReadOnly)) return 2;
    helper.startDemo(QJsonDocument::fromJson(f.readAll()).object());
  } else {
    HelperClient::Config cfg;
    // The bundled helper next to the binary, never one from PATH (architecture.md 1).
    cfg.program = state.arg("helper", QCoreApplication::applicationDirPath() + "/switch-core");
    cfg.root = state.arg("root");
    helper.start(cfg);
  }

  // A headless capture run has no tray; the window then quits the app on close.
  Tray tray;
  app.setQuitOnLastWindowClosed(!tray.available());

  QQmlApplicationEngine engine;
  helper.setEngine(&engine);
  engine.rootContext()->setContextProperty("App", &state);
  engine.rootContext()->setContextProperty("Helper", &helper);
  engine.rootContext()->setContextProperty("Tray", &tray);
#ifdef SWITCH_HARNESS
  Harness harness(state.arg("out", QDir::currentPath()));
  engine.rootContext()->setContextProperty("Harness", &harness);
  if (!state.arg("script").isEmpty()) QWindowSystemInterface::setSynchronousWindowSystemEvents(true);
#else
  engine.rootContext()->setContextProperty("Harness", nullptr);
#endif
  QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(2); },
                   Qt::QueuedConnection);
  engine.loadFromModule("SwitchUI", "Main");
  if (engine.rootObjects().isEmpty()) return 2;
  const int rc = app.exec();
  helper.stop();
  return rc;
}
