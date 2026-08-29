ARCHS = arm64 arm64e
TARGET = iphone:latest:16.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MatisuAuto
MatisuAuto_FILES = main.mm AppDelegate.mm TouchInject.mm ControlServer.mm
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
MatisuAuto_FRAMEWORKS = UIKit CoreGraphics Foundation
MatisuAuto_CODESIGN_ENTITLEMENTS = Entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	@install.exec "killall -9 MatisuAuto" 2>/dev/null || true
