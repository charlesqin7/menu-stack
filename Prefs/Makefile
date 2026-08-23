include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VerticalMenuPrefs

VLM_PKG_VERSION := $(shell awk '/^Version:/{print $$2; exit}' ../control)

VerticalMenuPrefs_FILES = VLMRootListController.m VLMOrderListController.m ../VLMMenuOrder.m
VerticalMenuPrefs_FRAMEWORKS = UIKit
VerticalMenuPrefs_PRIVATE_FRAMEWORKS = Preferences
VerticalMenuPrefs_INSTALL_PATH = /Library/PreferenceBundles
VerticalMenuPrefs_CFLAGS = -fobjc-arc -DVLM_VERSION=\"$(VLM_PKG_VERSION)\"
# Xcode public SDKs omit Preferences.framework; resolve PSListController on-device.
# -ObjC keeps VLMOrderListController in the binary so Settings can push it.
VerticalMenuPrefs_LDFLAGS = -undefined dynamic_lookup -ObjC

include $(THEOS_MAKE_PATH)/bundle.mk
