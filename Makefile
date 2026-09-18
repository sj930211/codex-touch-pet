SDK := $(shell xcrun --show-sdk-path)
CLANG := $(shell xcrun --find clang)
SWIFTC := $(shell xcrun --find swiftc)
CFLAGS := -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=11.0 -isysroot $(SDK)
FRAMEWORKS := -framework AppKit
APP_BUILD_DIR := .build/direct
APP_EXECUTABLE := $(APP_BUILD_DIR)/CodexTouchPet
APP_BUNDLE := .build/app/Codex Touch Pet.app
SWIFT_SOURCES := $(wildcard Sources/CodexTouchPet/*.swift)

.PHONY: all probe app run-app test-app clean

all: selector-probe touchbar-pet-poc

probe: selector-probe
	./selector-probe

selector-probe: selector_probe.m
	$(CLANG) $(CFLAGS) $< -o $@ $(FRAMEWORKS)

touchbar-pet-poc: touchbar_pet_poc.m
	$(CLANG) $(CFLAGS) $< -o $@ $(FRAMEWORKS) -framework QuartzCore

app:
	mkdir -p "$(APP_BUILD_DIR)" "$(APP_BUNDLE)/Contents/MacOS"
	$(CLANG) $(CFLAGS) -I Sources/TouchBarPrivate/include -c Sources/TouchBarPrivate/TouchBarPrivate.m -o "$(APP_BUILD_DIR)/TouchBarPrivate.o"
	$(SWIFTC) -O -sdk "$(SDK)" -target arm64-apple-macosx13.0 -import-objc-header Sources/TouchBarPrivate/include/TouchBarPrivate.h $(SWIFT_SOURCES) "$(APP_BUILD_DIR)/TouchBarPrivate.o" -framework AppKit -o "$(APP_EXECUTABLE)"
	cp "$(APP_EXECUTABLE)" "$(APP_BUNDLE)/Contents/MacOS/CodexTouchPet"
	cp "App/Info.plist" "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --force --sign - "$(APP_BUNDLE)"

run-app: app
	open "$(APP_BUNDLE)"

test-app:
	mkdir -p "$(APP_BUILD_DIR)"
	$(SWIFTC) -sdk "$(SDK)" -target arm64-apple-macosx13.0 Sources/CodexTouchPet/PetState.swift Tests/SelfTest/main.swift -framework AppKit -o "$(APP_BUILD_DIR)/pet-state-tests"
	"$(APP_BUILD_DIR)/pet-state-tests"

clean:
	rm -f selector-probe touchbar-pet-poc
	rm -f "$(APP_BUILD_DIR)/TouchBarPrivate.o" "$(APP_BUILD_DIR)/CodexTouchPet" "$(APP_BUILD_DIR)/pet-state-tests"
