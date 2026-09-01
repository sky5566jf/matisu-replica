ARCHS = arm64 arm64e
TARGET = iphone:latest:14.0
PACKAGE_VERSION = 0.1.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MatisuAuto
MatisuAuto_CFLAGS += -DLUA_USE_IOS -Wno-deprecated-declarations -Wno-module-import-in-extern-c
MatisuAuto_FILES = main.mm AppDelegate.mm MainVC.mm TouchInject.mm ControlServer.mm ScreenShot.m AXNodeDump.m DeviceInfo.m sthid/STHIDEventGenerator.mm LuaEngine.mm ColorFind.m PicFind.m SysUtil.m OcrEngine.mm $(filter-out lua/onelua.c,$(wildcard lua/*.c))
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
MatisuAuto_FRAMEWORKS = UIKit CoreGraphics Foundation IOSurface
MatisuAuto_RESOURCE_FILES = AppIcon60x60@2x.png AppIcon60x60@3x.png
MatisuAuto_CODESIGN_ENTITLEMENTS = Entitlements.plist
MatisuAuto_CFLAGS += -I../include -fobjc-arc

# OCR：onnxruntime iOS 静态库（CI 下载到 ios/ort/，见 ios.yml）
# ORT_ROOT 指向含 ios-arm64/onnxruntime.a 与 Headers 的 xcframework 目录
ORT_ROOT ?= ../ort/onnxruntime.xcframework
MatisuAuto_CFLAGS += -I$(ORT_ROOT)/Headers
MatisuAuto_CCFLAGS += -std=c++17
MatisuAuto_LDFLAGS = -Wl,-undefined,dynamic_lookup
MatisuAuto_LDFLAGS += $(ORT_ROOT)/ios-arm64/onnxruntime.a -lc++

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	@install.exec "killall -9 MatisuAuto" 2>/dev/null || true
