TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES = thermalmonitord Preferences
DEBUG = 0
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# 单一 dylib
TWEAK_NAME = insulation
insulation_FILES = Sources/insulation_rebuilt.m Sources/insulation_mitigation.m \
                   Sources/insulation_cpu.m Sources/insulation_state.m Sources/insulation_plist.m Sources/insulation_freq.m
insulation_FRAMEWORKS = Foundation CoreFoundation SystemConfiguration IOKit
insulation_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
insulation_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/aggregate.mk
