#include "harness.h"

#include <QCoreApplication>
#include <QDir>
#include <QImage>
#include <QQuickWindow>
#include <QTextStream>
#include <qpa/qwindowsysteminterface.h>

Harness::Harness(QString outDir, QObject *parent) : QObject(parent), m_outDir(std::move(outDir)) {
  QDir().mkpath(m_outDir);
}

QString Harness::shot(QObject *window, const QString &name) {
  auto *w = qobject_cast<QQuickWindow *>(window);
  if (!w) return "no-window";
  const QImage img = w->grabWindow();
  const QString path = m_outDir + "/" + name + ".png";
  if (!img.save(path, "PNG")) return "save-failed";
  return QString("%1x%2").arg(img.width()).arg(img.height());
}

static void mouse(QObject *o, qreal x, qreal y, Qt::MouseButtons state, Qt::MouseButton button, QEvent::Type type) {
  auto *w = qobject_cast<QWindow *>(o);
  if (!w) return;
  // this overload takes native pixels
  const qreal r = w->devicePixelRatio();
  QWindowSystemInterface::handleMouseEvent(w, QPointF(x * r, y * r), w->mapToGlobal(QPointF(x, y)) * r, state, button, type);
  QWindowSystemInterface::flushWindowSystemEvents();
}

void Harness::move(QObject *window, qreal x, qreal y) { mouse(window, x, y, Qt::NoButton, Qt::NoButton, QEvent::MouseMove); }

void Harness::click(QObject *window, qreal x, qreal y) {
  move(window, x, y);
  mouse(window, x, y, Qt::LeftButton, Qt::LeftButton, QEvent::MouseButtonPress);
  mouse(window, x, y, Qt::NoButton, Qt::LeftButton, QEvent::MouseButtonRelease);
}

void Harness::key(QObject *window, int key, int modifiers, const QString &text) {
  auto *w = qobject_cast<QWindow *>(window);
  if (!w) return;
  const auto mods = Qt::KeyboardModifiers(modifiers);
  QWindowSystemInterface::handleKeyEvent(w, QEvent::KeyPress, key, mods, text);
  QWindowSystemInterface::handleKeyEvent(w, QEvent::KeyRelease, key, mods, text);
  QWindowSystemInterface::flushWindowSystemEvents();
}

void Harness::log(const QString &line) const { QTextStream(stdout) << line << Qt::endl; }

void Harness::quit(int code) { QCoreApplication::exit(code); }
