#include "tray.h"

#include <QCursor>
#include <QGuiApplication>
#include <QScreen>
#include <QIcon>
#include <QImage>
#include <QMenu>
#include <QPainter>
#include <QPixmap>
#include <QSystemTrayIcon>

namespace {
QPixmap tinted(const QString &path, const QColor &color) {
  QImage img(path);
  img = img.convertToFormat(QImage::Format_ARGB32_Premultiplied);
  QPainter p(&img);
  p.setCompositionMode(QPainter::CompositionMode_SourceIn);
  p.fillRect(img.rect(), color);
  return QPixmap::fromImage(img);
}
} // namespace

Tray::Tray(QObject *parent) : QObject(parent) {
  if (!QSystemTrayIcon::isSystemTrayAvailable()) return;
  m_icon = new QSystemTrayIcon(this);
  m_menu = new QMenu;
  m_menu->addAction("Open Switch", this, &Tray::openRequested);
  m_menu->addAction("Refresh Usage", this, &Tray::refreshRequested);
  m_menu->addAction("Settings…", QKeySequence("Ctrl+,"), this, &Tray::settingsRequested);
  m_menu->addSeparator();
  m_menu->addAction("Quit Switch", QKeySequence("Ctrl+Q"), this, &Tray::quitRequested);
  m_icon->setContextMenu(m_menu);
  m_icon->setToolTip("Switch");
  connect(m_icon, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason r) {
    if (r == QSystemTrayIcon::Trigger) emit toggleRequested(iconRect());
  });
  updateIcon();
  m_icon->show();
}

Tray::~Tray() { delete m_menu; }

bool Tray::available() const { return m_icon != nullptr; }

void Tray::setDarkTray(bool dark) {
  if (dark == m_dark) return;
  m_dark = dark;
  updateIcon();
  emit darkTrayChanged();
}

QString Tray::tooltip() const { return m_icon ? m_icon->toolTip() : QString(); }

void Tray::setTooltip(const QString &text) {
  if (!m_icon || text == m_icon->toolTip()) return;
  m_icon->setToolTip(text);
  emit tooltipChanged();
}

QRect Tray::iconRect() const {
  if (!m_icon) return {};
  const QRect r = m_icon->geometry();
  // Wayland reports nothing; fall back to the pointer, as popover.md 8.2 says.
  return r.isValid() && !r.isEmpty() ? r : QRect(QCursor::pos(), QSize(1, 1));
}

QVariantMap Tray::place(QRect anchor, int width, int height) const {
  constexpr int margin = 8;
  QScreen *screen = QGuiApplication::screenAt(anchor.center());
  if (!screen) screen = QGuiApplication::primaryScreen();
  const QRect work = screen ? screen->availableGeometry() : QRect(0, 0, 1440, 900);
  const QRect full = screen ? screen->geometry() : work;
  const int maxHeight = qMax(94, int(work.height() * 0.8));
  height = qMin(height, maxHeight);
  // No anchor (Wayland without coordinates): the top-right corner of the work area, arrow hidden off-body.
  if (anchor.isEmpty() && anchor.topLeft().isNull()) anchor = QRect(work.right() - margin - width / 2, work.top(), 1, 1);
  const bool bottomTray = anchor.center().y() > full.center().y();
  const int x = qBound(work.left() + margin, anchor.center().x() - width / 2, work.right() - margin - width + 1);
  const int y = bottomTray ? qMax(work.top() + margin, anchor.top() - height) : qMax(work.top(), anchor.bottom() + 1);
  return {{"x", x}, {"y", y}, {"arrowX", anchor.center().x() - x}, {"arrowDown", bottomTray}, {"maxHeight", maxHeight}};
}

void Tray::updateIcon() {
  if (!m_icon) return;
  const QColor c = m_dark ? Qt::white : Qt::black;
  QIcon icon;
  icon.addPixmap(tinted(":/qt/qml/SwitchUI/assets/tray.png", c));
  icon.addPixmap(tinted(":/qt/qml/SwitchUI/assets/tray@2x.png", c));
  m_icon->setIcon(icon);
}
