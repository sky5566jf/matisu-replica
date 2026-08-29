ARCHS = arm64 arm64e
TARGET = iphone:latest:16.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MatisuAuto
MatisuAuto_FILES = main.mm AppDelegate.mm TouchInject.mm ../src/MatisuTouch.m
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
MatisuAuto_FRAMEWORKS = UIKit CoreGraphics Foundation
MatisuAuto_CODESIGN_ENTITLEMENTS = Entitlements.plist
MatisuAuto_CFLAGS = -I../include
MatisuAuto_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	@install.exec "killall -9 MatisuAuto" 2>/dev/null || true
