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

VerticalMenu_FILES = Tweak.x VLMMenuOrder.m VLMMenuRules.m
VerticalMenu_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable -Wno-unused-parameter -Wno-incompatible-pointer-types
VerticalMenu_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Application Support/VerticalMenu/inbox"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0777 "$(THEOS_STAGING_DIR)$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Application Support/VerticalMenu/inbox"$(ECHO_END)
