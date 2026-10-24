include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = InsulationPrefs
InsulationPrefs_FILES = INSRootListController.m
InsulationPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
InsulationPrefs_PRIVATE_FRAMEWORKS = Preferences
InsulationPrefs_INSTALL_PATH = /Library/PreferenceBundles
InsulationPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
InsulationPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
