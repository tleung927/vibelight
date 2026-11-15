TEMPLATE = app
TARGET = tst_awdlsuspend
QT = core testlib
CONFIG += console testcase c++17
CONFIG -= app_bundle
INCLUDEPATH += $$PWD/../../app
SOURCES += $$PWD/tst_awdlsuspend.cpp $$PWD/../../app/streaming/awdlsuspend.mm
HEADERS += $$PWD/../../app/streaming/awdlsuspend.h

!disable-prebuilts {
    INCLUDEPATH += $$PWD/../../libs/mac/include/SDL2 $$PWD/../../libs/mac/include
    LIBS += -L$$PWD/../../libs/mac/lib -lSDL2
    QMAKE_RPATHDIR += $$PWD/../../libs/mac/lib
}
