// Copyright (c) 2009-2018 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include <qt/test/uritests.h>

#include <qt/guiutil.h>
#include <qt/walletmodel.h>

#include <QUrl>

void URITests::uriTests()
{
    SendCoinsRecipient rv;
    QUrl uri;
    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?req-dontexist="));
    // !ALPHA END

    QVERIFY(!GUIUtil::parseBitcoinURI(uri, &rv));

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?dontexist="));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.label == QString());
    QVERIFY(rv.amount == 0);

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?label=Wikipedia Example Address"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.label == QString("Wikipedia Example Address"));
    QVERIFY(rv.amount == 0);

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=0.001"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.label == QString());
    QVERIFY(rv.amount == 100000);

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=1.001"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.label == QString());
    QVERIFY(rv.amount == 100100000);

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=100&label=Wikipedia Example"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.amount == 10000000000LL);
    QVERIFY(rv.label == QString("Wikipedia Example"));

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?message=Wikipedia Example Address"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.label == QString());

    // !ALPHA
    QVERIFY(GUIUtil::parseBitcoinURI("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?message=Wikipedia Example Address", &rv));
    // !ALPHA END
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.label == QString());

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?req-message=Wikipedia Example Address"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));

    // Commas in amounts are not allowed.
    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=1,000&label=Wikipedia Example"));
    // !ALPHA END
    QVERIFY(!GUIUtil::parseBitcoinURI(uri, &rv));

    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=1,000.0&label=Wikipedia Example"));
    // !ALPHA END
    QVERIFY(!GUIUtil::parseBitcoinURI(uri, &rv));

    // There are two amount specifications. The last value wins.
    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=100&amount=200&label=Wikipedia Example"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.amount == 20000000000LL);
    QVERIFY(rv.label == QString("Wikipedia Example"));

    // The first amount value is correct. However, the second amount value is not valid. Hence, the URI is not valid.
    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=100&amount=1,000&label=Wikipedia Example"));
    // !ALPHA END
    QVERIFY(!GUIUtil::parseBitcoinURI(uri, &rv));

    // Test label containing a question mark ('?').
    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=100&label=?"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.amount == 10000000000LL);
    QVERIFY(rv.label == QString("?"));

    // Escape sequences are not supported.
    // !ALPHA
    uri.setUrl(QString("alpha:175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W?amount=100&label=%3F"));
    // !ALPHA END
    QVERIFY(GUIUtil::parseBitcoinURI(uri, &rv));
    QVERIFY(rv.address == QString("175tWpb8K1S7NmH4Zx6rewF9WQrcZv245W"));
    QVERIFY(rv.amount == 10000000000LL);
    QVERIFY(rv.label == QString("%3F"));
}
