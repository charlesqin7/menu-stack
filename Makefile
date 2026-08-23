export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64 arm64e

# Default rootless. Override in CI/local:
#   make package THEOS_PACKAGE_SCHEME=rootless
#   make package THEOS_PACKAGE_SCHEME=roothide
ifeq ($(THEOS_PACKAGE_SCHEME),)
export THEOS_PACKAGE_SCHEME = rootless
endif

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VerticalMenu

VerticalMenu_FILES = Tweak.x VLMMenuOrder.m
VerticalMenu_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter -Wno-incompatible-pointer-types
VerticalMenu_FRAMEWORKS = UIKit Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"
