ARCHS = arm64 arm64e
TARGET = iphone:latest:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MatisuAuto
MatisuAuto_FILES = main.mm AppDelegate.mm TouchInject.mm ControlServer.mm ScreenShot.m AXNodeDump.m DeviceInfo.m sthid/STHIDEventGenerator.mm
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
MatisuAuto_FRAMEWORKS = UIKit CoreGraphics Foundation IOSurface
MatisuAuto_CODESIGN_ENTITLEMENTS = Entitlements.plist
MatisuAuto_CFLAGS = -I../include -fobjc-arc
MatisuAuto_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	@install.exec "killall -9 MatisuAuto" 2>/dev/null || true
