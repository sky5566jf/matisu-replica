ARCHS = arm64 arm64e
TARGET = iphone:clang:16.0
INSTALL_TARGET = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MatisuAuto
MatisuAuto_FILES = Tweak.xm
# 触控注入依赖 IOKit 私有头（ digitizer 事件 / IOHIDEventSystemClient ）
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
# 若改为 backboardd 注入路径，可追加 BackBoardServices

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	@install.exec "killall -9 backboardd" 2>/dev/null || true
