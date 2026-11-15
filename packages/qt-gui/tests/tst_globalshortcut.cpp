// The menu shortcut in the XDG shortcuts format that the GlobalShortcuts portal takes as preferred_trigger.
#include <QSet>
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

  // settings.md 2.1 stores the Mac virtual key code (Carbon kVK_*).
  void macKeyCodes() {
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_A), 0x00);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_S), 0x01);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_0), 0x1D);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_Return), 0x24);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_Space), 0x31);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_QuoteLeft), 0x32);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_F1), 0x7A);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_F12), 0x6F);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_Up), 0x7E);
    QCOMPARE(GlobalShortcut::macKeyCode(Qt::Key_VolumeUp), -1);
    QCOMPARE(GlobalShortcut::qtKey(0x7F), 0);   // no kVK at 0x7F
    QCOMPARE(GlobalShortcut::qtKey(-1), 0);
  }
  // Every mapped key goes both ways, codes are unique, and each one can be bound (XDG name and X11 keysym).
  void macTableRoundTrip() {
    QSet<int> codes;
    for (int key = 0; key < 0x01ffffff; key = key < 0x7f ? key + 1 : (key < Qt::Key_Escape ? Qt::Key_Escape : key + 1)) {
      if (key > Qt::Key_F35) break;
      const int code = GlobalShortcut::macKeyCode(key);
      if (code < 0) continue;
      QVERIFY2(!codes.contains(code), qPrintable(QString::number(code)));
      codes.insert(code);
      QCOMPARE(GlobalShortcut::qtKey(code), key);
      QVERIFY(!GlobalShortcut::xdgTrigger(key, 4096).isEmpty());
      QVERIFY(GlobalShortcut::keysym(key) != 0);
    }
    QCOMPARE(codes.size(), 82);
  }
  void keysyms() {
    QCOMPARE(GlobalShortcut::keysym(Qt::Key_S), 0x73u);
    QCOMPARE(GlobalShortcut::keysym(Qt::Key_5), 0x35u);
    QCOMPARE(GlobalShortcut::keysym(Qt::Key_F1), 0xffbeu);
    QCOMPARE(GlobalShortcut::keysym(Qt::Key_Return), 0xff0du);
  }
};

QTEST_GUILESS_MAIN(TstGlobalShortcut)
#include "tst_globalshortcut.moc"
