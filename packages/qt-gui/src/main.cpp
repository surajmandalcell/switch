#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QIcon>
#include <QJsonDocument>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QSGRendererInterface>

#include "appstate.h"
#include "helperclient.h"
#include "notifier.h"
#include "tray.h"
#ifdef SWITCH_HARNESS
#include "harness.h"
#include <qpa/qwindowsysteminterface.h>
#endif

int main(int argc, char *argv[]) {
  // The only Quick Controls in the app are the non-native folder dialog's; the packages ship only the Basic style.
  if (!qEnvironmentVariableIsSet("QT_QUICK_CONTROLS_STYLE")) qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");
#ifndef Q_OS_WIN
  // Windows keeps Qt's default Direct3D 11, which also runs (WARP) where no OpenGL driver is installed.
  if (!qEnvironmentVariableIsSet("QSG_RHI_BACKEND")) QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
#endif

  // The app id (packaging/linux/com.mandalsuraj.Switch.desktop): the Wayland app_id and Qt's own portal
  // registration use it, so set it before the application starts the platform.
  QGuiApplication::setDesktopFileName("com.mandalsuraj.Switch");
  QApplication app(argc, argv);
  // Qt 6.12 Wayland: with the threaded render loop, hiding the popover and showing it again soon after can
  // crash the render thread in QWaylandWindow::beginFrame (3 of 4 packaged runs). The basic loop renders on
  // the GUI thread and has no such race. Read when the first window starts its scene graph, so set it here.
  if (QGuiApplication::platformName().startsWith("wayland") && !qEnvironmentVariableIsSet("QSG_RENDER_LOOP"))
    qputenv("QSG_RENDER_LOOP", "basic");
  app.setApplicationName("Switch");
  app.setApplicationVersion("0.1.0");
  app.setWindowIcon(QIcon(":/qt/qml/SwitchUI/assets/appicon.png"));
  // macOS draws text with grayscale antialiasing; an RGB-subpixel fontconfig default would add color fringes.
  QFont base = QGuiApplication::font();
  base.setStyleStrategy(QFont::NoSubpixelAntialias);
  QGuiApplication::setFont(base);

  const int fontId = QFontDatabase::addApplicationFont(":/qt/qml/SwitchUI/fonts/InterVariable.ttf");
  const QStringList fams = QFontDatabase::applicationFontFamilies(fontId);
  // SF Mono stand-in for paths, IDs and code (design-system.md 2.3); Theme.monoFamily names it.
  QFontDatabase::addApplicationFont(":/qt/qml/SwitchUI/fonts/JetBrainsMono-Regular.ttf");
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
#ifdef Q_OS_WIN
    cfg.program = state.arg("helper", QCoreApplication::applicationDirPath() + "/switch-core.exe");
#else
    cfg.program = state.arg("helper", QCoreApplication::applicationDirPath() + "/switch-core");
#endif
    cfg.root = state.arg("root");
    helper.start(cfg);
  }

  // A headless capture run has no tray; the window then quits the app on close.
  Tray tray;
  app.setQuitOnLastWindowClosed(!tray.available());

  // Quota alerts come from the helper (rpc.md notify.post, group switch.quota); pages post action messages
  // through Notify.post. A click raises the main window (Main.qml listens to Notify.activated).
  Notifier notifier;
  QObject::connect(&notifier, &Notifier::fallback, &tray, &Tray::showMessage);
  QObject::connect(&helper, &HelperClient::notification, &notifier, [&notifier](const QString &method, const QJsonObject &p) {
    if (method != "notify.post") return;
    notifier.post(p.value("id").toString(), p.value("title").toString(), p.value("subtitle").toString(),
                  p.value("body").toString(), p.value("group").toString() == "switch.quota");
  });

  QQmlApplicationEngine engine;
  helper.setEngine(&engine);
  engine.rootContext()->setContextProperty("App", &state);
  engine.rootContext()->setContextProperty("Helper", &helper);
  engine.rootContext()->setContextProperty("Tray", &tray);
  engine.rootContext()->setContextProperty("Notify", &notifier);
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
