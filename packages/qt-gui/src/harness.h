#pragma once
// Dev-only screenshot and input harness (SWITCH_HARNESS). Input goes through QWindowSystemInterface, the
// same path as real pointer and key events. Uses private Qt headers; shipping builds leave it out.
#include <QObject>
#include <QString>

class Harness : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString outDir MEMBER m_outDir CONSTANT)
public:
  explicit Harness(QString outDir, QObject *parent = nullptr);
  Q_INVOKABLE QString shot(QObject *window, const QString &name);
  Q_INVOKABLE void move(QObject *window, qreal x, qreal y);
  Q_INVOKABLE void click(QObject *window, qreal x, qreal y);
  Q_INVOKABLE void key(QObject *window, int key, int modifiers = 0, const QString &text = QString());
  Q_INVOKABLE void log(const QString &line) const;
  Q_INVOKABLE void quit(int code = 0);

private:
  QString m_outDir;
};
