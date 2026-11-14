#pragma once
// Tray icon (popover.md 1, 8): left click toggles the popover, right click shows the four-item menu.
// The template mark is recolored per tray tone, because no Linux or Windows tray tints images.
#include <QObject>
#include <QRect>
#include <QVariantMap>

class QMenu;
class QSystemTrayIcon;

class Tray : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool available READ available CONSTANT)
  Q_PROPERTY(bool darkTray READ darkTray WRITE setDarkTray NOTIFY darkTrayChanged)
  Q_PROPERTY(QString tooltip READ tooltip WRITE setTooltip NOTIFY tooltipChanged)
public:
  explicit Tray(QObject *parent = nullptr);
  ~Tray() override;
  bool available() const;
  bool darkTray() const { return m_dark; }
  void setDarkTray(bool dark);
  QString tooltip() const;
  void setTooltip(const QString &text);
  // Icon rectangle in global logical pixels; empty when the platform does not tell (Wayland).
  Q_INVOKABLE QRect iconRect() const;
  // popover.md 8.2: center the body on the anchor, clamp to the anchor screen's work area with an
  // 8 px margin, open below a top tray and above a bottom one. Returns {x, y, arrowX, arrowDown, maxHeight}
  // for a body `width` wide and `height` tall (arrow included, no shadow margin).
  Q_INVOKABLE QVariantMap place(QRect anchor, int width, int height) const;

signals:
  void toggleRequested(QRect anchor);
  void openRequested();
  void refreshRequested();
  void settingsRequested();
  void quitRequested();
  void darkTrayChanged();
  void tooltipChanged();

private:
  void updateIcon();
  QSystemTrayIcon *m_icon = nullptr;
  QMenu *m_menu = nullptr;
  bool m_dark = true;
};
