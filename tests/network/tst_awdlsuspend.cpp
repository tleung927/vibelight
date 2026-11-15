#include <QtTest>

#include "streaming/awdlsuspend.h"

// These tests never call sudo or change the interface: they cover the rule
// text, the disabled path and the read-only state query.
class TestAwdlSuspend : public QObject
{
    Q_OBJECT

private slots:
    void ruleAllowsOnlyTheTwoCommands()
    {
        const QString rule = AwdlSuspendHold::sudoersRule("tonysmac");
        const QStringList lines = rule.trimmed().split('\n');
        QCOMPARE(lines.size(), 2);
        QCOMPARE(lines[0], QStringLiteral("tonysmac ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 down"));
        QCOMPARE(lines[1], QStringLiteral("tonysmac ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 up"));
    }

    void ruleRejectsUnsafeUserNames_data()
    {
        QTest::addColumn<QString>("name");
        QTest::newRow("empty") << QString();
        QTest::newRow("space") << QStringLiteral("bad user");
        QTest::newRow("quote") << QStringLiteral("a'b");
        QTest::newRow("shell") << QStringLiteral("a;rm -rf /");
        QTest::newRow("newline") << QStringLiteral("a\nALL ALL=(ALL) ALL");
        QTest::newRow("wildcard") << QStringLiteral("ALL,root");
        QTest::newRow("leading dash") << QStringLiteral("-x");
    }

    void ruleRejectsUnsafeUserNames()
    {
        QFETCH(QString, name);
        QVERIFY(AwdlSuspendHold::sudoersRule(name).isEmpty());
    }

    void disabledHoldDoesNothing()
    {
        const bool before = AwdlSuspendHold::isInterfaceUp();
        {
            AwdlSuspendHold hold(false);
            QVERIFY(!hold.isHolding());
        }
        QCOMPARE(AwdlSuspendHold::isInterfaceUp(), before);
    }

    void missingInterfaceReadsAsDown()
    {
        QVERIFY(!AwdlSuspendHold::isInterfaceUp("nosuchif9"));
    }

    void loopbackReadsAsUp()
    {
        QVERIFY(AwdlSuspendHold::isInterfaceUp("lo0"));
    }
};

QTEST_GUILESS_MAIN(TestAwdlSuspend)
#include "tst_awdlsuspend.moc"
