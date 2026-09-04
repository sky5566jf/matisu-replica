# 仅构建 arm64：当前 ORT 静态库（csukuangfj v1.17.1）只含 ios-arm64 切片，
# 不含 ios-arm64e，故 arm64e 目标无法链到 ORT 符号。arm64 二进制在 arm64e 设备上
# 以兼容模式原生运行（已在 SE2 真机验证），无需单独 arm64e 产物。
ARCHS = arm64
TARGET = iphone:latest:14.0
PACKAGE_VERSION = 0.1.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MatisuAuto
MatisuAuto_CFLAGS += -DLUA_USE_IOS -Wno-deprecated-declarations -Wno-module-import-in-extern-c
MatisuAuto_FILES = main.mm AppDelegate.mm MainVC.mm TouchInject.mm ControlServer.mm ScreenShot.m AXNodeDump.m DeviceInfo.m sthid/STHIDEventGenerator.mm LuaEngine.mm ColorFind.m PicFind.m SysUtil.m OcrEngine.mm Watchdog.m MatisuPaths.m PackageManager.m MatisuHotspotManager.m $(filter-out lua/onelua.c,$(wildcard lua/*.c))
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
MatisuAuto_FRAMEWORKS = UIKit CoreGraphics Foundation IOSurface NetworkExtension SystemConfiguration
MatisuAuto_RESOURCE_FILES = AppIcon60x60@2x.png AppIcon60x60@3x.png
MatisuAuto_CODESIGN_ENTITLEMENTS = Entitlements.plist
MatisuAuto_CFLAGS += -I../include -fobjc-arc

# OCR：onnxruntime iOS 静态库（CI 下载到 ios/ort/，见 ios.yml）
# ORT_ROOT 指向含 ios-arm64/onnxruntime.a 与 Headers 的 xcframework 目录。
# 注意：csukuangfj v1.17.1 仅含 ios-arm64 切片（无 ios-arm64e），故统一构建 arm64（ARCHS = arm64）。
# arm64 二进制在 arm64e 设备上以兼容模式原生运行（已于 SE2 真机验证），无需单独 arm64e 产物。
ORT_ROOT ?= ../ort/onnxruntime.xcframework
MatisuAuto_CFLAGS += -I$(ORT_ROOT)/Headers
MatisuAuto_CCFLAGS += -std=c++17 -Wno-unused-result -Wno-error=unused-result
MatisuAuto_LDFLAGS = -Wl,-undefined,dynamic_lookup -lz
MatisuAuto_LDFLAGS += $(ORT_ROOT)/ios-arm64/onnxruntime.a -lc++

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	@install.exec "killall -9 MatisuAuto" 2>/dev/null || true
