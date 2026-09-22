SDK := $(shell xcrun --show-sdk-path)
CLANG := $(shell xcrun --find clang)
SWIFTC := $(shell xcrun --find swiftc)
CFLAGS := -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=11.0 -isysroot $(SDK) -fmodules-cache-path=.build/module-cache
FRAMEWORKS := -framework AppKit
MODULE_CACHE_DIR := .build/module-cache
SWIFT_MODULE_CACHE_FLAGS := -module-cache-path "$(MODULE_CACHE_DIR)"
APP_BUILD_DIR := .build/direct
APP_EXECUTABLE := $(APP_BUILD_DIR)/CodexTouchPet
APP_BUNDLE := .build/app/Codex Touch Pet.app
APP_PACKAGE_DIR := .build/package
APP_PACKAGE_BUNDLE := $(APP_PACKAGE_DIR)/Codex Touch Pet.app
APP_FOX_RESOURCES := Resources/Fox
SWIFT_SOURCES := $(wildcard Sources/CodexTouchPet/*.swift)

.PHONY: all probe app package run-app run-direct test-app clean

all: selector-probe touchbar-pet-poc

probe: selector-probe
	./selector-probe

selector-probe: selector_probe.m
	$(CLANG) $(CFLAGS) $< -o $@ $(FRAMEWORKS)

touchbar-pet-poc: touchbar_pet_poc.m
	$(CLANG) $(CFLAGS) $< -o $@ $(FRAMEWORKS) -framework QuartzCore

app:
	mkdir -p "$(APP_BUILD_DIR)" "$(MODULE_CACHE_DIR)" "$(APP_BUNDLE)/Contents/MacOS"
	$(CLANG) $(CFLAGS) -I Sources/TouchBarPrivate/include -c Sources/TouchBarPrivate/TouchBarPrivate.m -o "$(APP_BUILD_DIR)/TouchBarPrivate.o"
	$(SWIFTC) $(SWIFT_MODULE_CACHE_FLAGS) -O -sdk "$(SDK)" -target arm64-apple-macosx13.0 -import-objc-header Sources/TouchBarPrivate/include/TouchBarPrivate.h $(SWIFT_SOURCES) "$(APP_BUILD_DIR)/TouchBarPrivate.o" -framework AppKit -o "$(APP_EXECUTABLE)"
	cp "$(APP_EXECUTABLE)" "$(APP_BUNDLE)/Contents/MacOS/CodexTouchPet"
	cp "App/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources/Fox"
	cp "$(APP_FOX_RESOURCES)"/*.png "$(APP_BUNDLE)/Contents/Resources/Fox/"
	cp README.md "$(APP_BUNDLE)/Contents/Resources/README.md"
	cp NOTICE.txt "$(APP_BUNDLE)/Contents/Resources/NOTICE.txt"
	codesign --force --sign - "$(APP_BUNDLE)"

package: app
	./scripts/package-app.sh

run-app: app
	open "$(APP_BUNDLE)"

run-direct: app
	"$(APP_EXECUTABLE)"

test-app:
	mkdir -p "$(APP_BUILD_DIR)" "$(MODULE_CACHE_DIR)"
	$(SWIFTC) $(SWIFT_MODULE_CACHE_FLAGS) -sdk "$(SDK)" -target arm64-apple-macosx13.0 Sources/CodexTouchPet/AppSettings.swift Sources/CodexTouchPet/CodexThreadLink.swift Sources/CodexTouchPet/PetState.swift Sources/CodexTouchPet/ThreadStatusStore.swift Tests/SelfTest/main.swift -framework AppKit -o "$(APP_BUILD_DIR)/pet-state-tests"
	"$(APP_BUILD_DIR)/pet-state-tests"

clean:
	rm -f selector-probe touchbar-pet-poc
	rm -f "$(APP_BUILD_DIR)/TouchBarPrivate.o" "$(APP_BUILD_DIR)/CodexTouchPet" "$(APP_BUILD_DIR)/pet-state-tests"
