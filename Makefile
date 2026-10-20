CXX = clang++
SWIFTC = swiftc

PLUGIN_SRC = plugin/libchiaki_ucr.mm
PLUGIN_OUT = plugin/libchiaki_ucr.dylib
SHARED_HDR = plugin/chiaki_ucr_shared.h

APP_SRC = app/ChiakiUCRApp.swift
APP_OUT = Chiaki-UCR.app/Contents/MacOS/Chiaki-UCR

all: $(PLUGIN_OUT) $(APP_OUT)

$(PLUGIN_OUT): $(PLUGIN_SRC) $(SHARED_HDR)
	$(CXX) -dynamiclib -std=c++17 -O2 -arch arm64 \
		-framework Cocoa -framework CoreGraphics -framework Carbon \
		$(PLUGIN_SRC) -o $(PLUGIN_OUT)
	codesign --force --sign - $(PLUGIN_OUT)

$(APP_OUT): $(APP_SRC) $(SHARED_HDR) $(PLUGIN_OUT) app/Info.plist
	mkdir -p Chiaki-UCR.app/Contents/MacOS Chiaki-UCR.app/Contents/Frameworks Chiaki-UCR.app/Contents/Resources
	cp app/Info.plist Chiaki-UCR.app/Contents/Info.plist
	cp app/AppIcon.icns Chiaki-UCR.app/Contents/Resources/AppIcon.icns
	cp $(PLUGIN_OUT) Chiaki-UCR.app/Contents/Frameworks/
	TMPDIR=/tmp $(SWIFTC) -O -parse-as-library -module-cache-path /tmp/swift-module-cache \
		-import-objc-header $(SHARED_HDR) \
		$(APP_SRC) -o $(APP_OUT)
	rm -f Chiaki-UCR.app/Icon*
	xattr -cr Chiaki-UCR.app
	codesign --force --deep --sign - Chiaki-UCR.app

release: all
	rm -f Chiaki-UCR-macOS-arm64.zip
	ditto -c -k --sequesterRsrc --keepParent Chiaki-UCR.app Chiaki-UCR-macOS-arm64.zip
	@echo "Release bundle created: Chiaki-UCR-macOS-arm64.zip"

clean:
	rm -rf $(PLUGIN_OUT) $(APP_OUT) Chiaki-UCR.app/Contents/Frameworks Chiaki-UCR-macOS-arm64.zip
