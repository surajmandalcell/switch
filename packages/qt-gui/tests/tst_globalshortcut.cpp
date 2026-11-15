// The menu shortcut in the XDG shortcuts format that the GlobalShortcuts portal takes as preferred_trigger.
#include <QTest>

#include "globalshortcut.h"

class TstGlobalShortcut : public QObject {
  Q_OBJECT
private slots:
  void trigger_data() {
    QTest::addColumn<int>("key");
    QTest::addColumn<int>("mods");   // Carbon mask: Control 4096, Option 2048, Shift 512, Command 256
    QTest::addColumn<QString>("want");
    QTest::newRow("ctrl alt s") << int(Qt::Key_S) << (4096 | 2048) << "CTRL+ALT+s";
    QTest::newRow("all four") << int(Qt::Key_K) << (4096 | 2048 | 512 | 256) << "CTRL+ALT+SHIFT+LOGO+k";
    QTest::newRow("digit") << int(Qt::Key_5) << 256 << "LOGO+5";
    QTest::newRow("f12") << int(Qt::Key_F12) << 4096 << "CTRL+F12";
    QTest::newRow("space") << int(Qt::Key_Space) << 2048 << "ALT+space";
    QTest::newRow("page up") << int(Qt::Key_PageUp) << 4096 << "CTRL+Prior";
    QTest::newRow("grave") << int(Qt::Key_QuoteLeft) << 4096 << "CTRL+grave";
    QTest::newRow("no keysym name") << int(Qt::Key_Exclam) << 4096 << "";
  }
  void trigger() {
    QFETCH(int, key);
    QFETCH(int, mods);
    QFETCH(QString, want);
    QCOMPARE(GlobalShortcut::xdgTrigger(key, mods), want);
  }
};

QTEST_GUILESS_MAIN(TstGlobalShortcut)
#include "tst_globalshortcut.moc"
