#pragma once
// Process-wide state the QML needs: command-line flags, the font family, and keyboard mode
// (focus tint shows only after a key moved focus, never after a click: design-system.md 4.17).
#include <QObject>
#include <QRect>
#include <QStringList>

class AppState : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString fontFamily MEMBER m_fontFamily CONSTANT)
  Q_PROPERTY(bool keyboardMode READ keyboardMode NOTIFY keyboardModeChanged)
public:
  AppState(QStringList args, QString fontFamily, QObject *parent = nullptr);
  Q_INVOKABLE QString arg(const QString &name, const QString &def = QString()) const;
  Q_INVOKABLE bool flag(const QString &name) const;
  // Usable area (no panels or taskbar) of the screen that holds `window`, in logical pixels.
  Q_INVOKABLE QRect workArea(QObject *window) const;
  bool keyboardMode() const { return m_keyboardMode; }

signals:
  void keyboardModeChanged();

protected:
  bool eventFilter(QObject *watched, QEvent *event) override;

private:
  QStringList m_args;
  QString m_fontFamily;
  bool m_keyboardMode = false;
};
