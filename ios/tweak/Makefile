ARCHS = arm64 arm64e
TARGET = iphone:latest:14.0
INSTALL_TARGET = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MatisuAuto
MatisuAuto_FILES = Tweak.xm ../src/MatisuTouch.m
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
MatisuAuto_CFLAGS = -I../include
MatisuAuto_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	@install.exec "killall -9 backboardd" 2>/dev/null || true
