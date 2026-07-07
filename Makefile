PROJECT := Bluesnooze.xcodeproj
SCHEME := Bluesnooze
CONFIGURATION ?= Debug

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION)
XCODEBUILD_UNSIGNED := $(XCODEBUILD) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=

.PHONY: bootstrap lint lint-fix build ci

bootstrap:
	brew bundle

lint:
	swiftlint lint --strict

lint-fix:
	swiftlint --fix
	swiftlint lint --strict

build:
	$(XCODEBUILD_UNSIGNED) build

ci: lint build
