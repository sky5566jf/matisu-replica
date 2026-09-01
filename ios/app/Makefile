# 仅构建 arm64：当前 ORT 静态库（csukuangfj v1.17.1）只含 ios-arm64 切片，
# 不含 ios-arm64e，故 arm64e 目标无法链到 ORT 符号。arm64 二进制在 arm64e 设备上
# 以兼容模式原生运行（已在 SE2 真机验证），无需单独 arm64e 产物。
ARCHS = arm64
TARGET = iphone:latest:14.0
PACKAGE_VERSION = 0.1.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MatisuAuto
MatisuAuto_CFLAGS += -DLUA_USE_IOS -Wno-deprecated-declarations -Wno-module-import-in-extern-c
MatisuAuto_FILES = main.mm AppDelegate.mm MainVC.mm TouchInject.mm ControlServer.mm ScreenShot.m AXNodeDump.m DeviceInfo.m sthid/STHIDEventGenerator.mm LuaEngine.mm ColorFind.m PicFind.m SysUtil.m OcrEngine.mm Watchdog.m $(filter-out lua/onelua.c,$(wildcard lua/*.c))
MatisuAuto_PRIVATE_FRAMEWORKS = IOKit
MatisuAuto_FRAMEWORKS = UIKit CoreGraphics Foundation IOSurface
MatisuAuto_RESOURCE_FILES = AppIcon60x60@2x.png AppIcon60x60@3x.png
MatisuAuto_CODESIGN_ENTITLEMENTS = Entitlements.plist
MatisuAuto_CFLAGS += -I../include -fobjc-arc

# OCR：onnxruntime iOS 静态库（CI 下载到 ios/ort/，见 ios.yml）
# ORT_ROOT 指向含 ios-arm64/onnxruntime.a 与 Headers 的 xcframework 目录。
# 注意：csukuangfj v1.17.1 仅含 ios-arm64 切片（无 ios-arm64e），故统一构建 arm64。
ORT_ROOT ?= ../ort/onnxruntime.xcframework
ORT_ARM64  := $(ORT_ROOT)/ios-arm64/onnxruntime.a
ORT_ARM64E := $(ORT_ROOT)/ios-arm64e/onnxruntime.a
ORT_FAT    := $(ORT_ROOT)/onnxruntime_fat.a
# 把 arm64 + arm64e 两切片合并成 FAT 静态库（仅当 arm64e 切片存在时），
# 这样无论目标架构是 arm64 还是 arm64e，链接器都能从同一份 .a 取到正确切片，
# 避免 arm64e 构建误链 arm64-only 的 .a 导致 _OrtGetApiBase 等符号未定义、daemon 启动即崩。
# 若 arm64e 切片缺失则退化为仅复制 arm64（arm64e 目标的 OCR 将不可用，但链接不报错，
# 由 -Wl,-undefined,dynamic_lookup 兜底，不会在启动时崩溃）。
$(shell test -f "$(ORT_FAT)" || { \
  if [ -f "$(ORT_ARM64E)" ]; then \
    echo "[ort] lipo merge ios-arm64 + ios-arm64e -> onnxruntime_fat.a"; \
    lipo -create "$(ORT_ARM64)" "$(ORT_ARM64E)" -output "$(ORT_FAT)"; \
  else \
    echo "[ort] arm64e slice missing, copy ios-arm64 only"; \
    cp "$(ORT_ARM64)" "$(ORT_FAT)"; \
  fi; } 2>/dev/null)
MatisuAuto_CFLAGS += -I$(ORT_ROOT)/Headers
MatisuAuto_CCFLAGS += -std=c++17 -Wno-unused-result -Wno-error=unused-result
MatisuAuto_LDFLAGS = -Wl,-undefined,dynamic_lookup
MatisuAuto_LDFLAGS += $(ORT_FAT) -lc++

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	@install.exec "killall -9 MatisuAuto" 2>/dev/null || true
