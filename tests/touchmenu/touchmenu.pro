TEMPLATE = app
TARGET = tst_touchmenu
QT = core testlib
CONFIG += console testcase c++17
CONFIG -= app_bundle
INCLUDEPATH += $$PWD/../../app
SOURCES += $$PWD/tst_touchmenu.cpp \
    $$PWD/../../app/streaming/input/touchmenu.cpp
HEADERS += $$PWD/../../app/streaming/input/touchmenu.h
