.PHONY: build test app run install zip icon demo demo-stop clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	-pkill -x AWSContext; sleep 1
	open build/AWSContext.app

install: app
	-pkill -x AWSContext; sleep 1
	rm -rf /Applications/AWSContext.app
	cp -R build/AWSContext.app /Applications/
	open /Applications/AWSContext.app

zip: app
	cd build && ditto -c -k --keepParent AWSContext.app AWSContext-$$(cat ../VERSION).zip

demo: app
	./scripts/demo.sh

demo-stop:
	./scripts/demo.sh stop

icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build
