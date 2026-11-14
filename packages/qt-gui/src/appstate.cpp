#include "appstate.h"

#include <QEvent>
#include <QGuiApplication>
#include <QScreen>
#include <QWindow>
#include <QKeyEvent>

AppState::AppState(QStringList args, QString fontFamily, QObject *parent)
    : QObject(parent), m_args(std::move(args)), m_fontFamily(std::move(fontFamily)) {}

QString AppState::arg(const QString &name, const QString &def) const {
  const QString key = "--" + name;
  for (int i = 0; i < m_args.size(); ++i) {
    if (m_args[i] == key && i + 1 < m_args.size()) return m_args[i + 1];
    if (m_args[i].startsWith(key + "=")) return m_args[i].mid(key.size() + 1);
  }
  return def;
}

bool AppState::flag(const QString &name) const { return m_args.contains("--" + name); }

QRect AppState::workArea(QObject *window) const {
  auto *w = qobject_cast<QWindow *>(window);
  QScreen *s = w && w->screen() ? w->screen() : QGuiApplication::primaryScreen();
  return s ? s->availableGeometry() : QRect();
}

bool AppState::eventFilter(QObject *watched, QEvent *event) {
  bool next = m_keyboardMode;
  if (event->type() == QEvent::KeyPress) {
    const int k = static_cast<QKeyEvent *>(event)->key();
    if (k == Qt::Key_Tab || k == Qt::Key_Backtab || k == Qt::Key_Up || k == Qt::Key_Down) next = true;
  } else if (event->type() == QEvent::MouseButtonPress) {
    next = false;
  }
  if (next != m_keyboardMode) {
    m_keyboardMode = next;
    emit keyboardModeChanged();
  }
  return QObject::eventFilter(watched, event);
}
