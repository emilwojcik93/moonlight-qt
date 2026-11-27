TEMPLATE = app
TARGET = tst_posture
QT = core testlib
CONFIG += console testcase c++17
CONFIG -= app_bundle
INCLUDEPATH += $$PWD/../../app
SOURCES += $$PWD/tst_posture.cpp \
    $$PWD/../../app/backend/postureclassifier.cpp \
    $$PWD/../../app/backend/displayautoconfig.cpp
HEADERS += $$PWD/../../app/backend/postureclassifier.h \
    $$PWD/../../app/backend/displayautoconfig.h
