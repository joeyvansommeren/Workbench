# Workbench

Workbench is a personal fork of [phxlle/AgentHub](https://github.com/phxlle/AgentHub), which is a fork of [jamesrochabrun/AgentHub](https://github.com/jamesrochabrun/AgentHub). MIT licensed — keep `LICENSE`.

## What differs from upstream

- The app is `Workbench.app`, bundle ID `com.joeyvansommeren.Workbench`.
- The Swift module is still `AgentHub` (`PRODUCT_MODULE_NAME`), so code, tests, and internal identifiers keep the upstream names. Only visible labels say Workbench.
- Sparkle auto-update is off. The upstream feed would replace this fork with upstream builds. There is no Workbench release feed.

## Update the installed app

There is no auto-update. Merging a PR does not change `/Applications/Workbench.app`. After merging, run from a checkout of `main`:

```bash
make update    # pull main, build, replace /Applications/Workbench.app, relaunch
make install   # same, for the current checkout, without pulling
```

## Build

Requires Xcode, `brew install libgit2 pkgconf`.

```bash
xcodebuild -workspace app/AgentHub.xcodeproj/project.xcworkspace -scheme AgentHub \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates \
  -skipPackagePluginValidation -skipMacroValidation build
open build/DerivedData/Build/Products/Debug/Workbench.app
```

## Pull upstream changes

```bash
git fetch upstream
git merge upstream/main
```

Expect conflicts in `project.pbxproj` and `Info.plist` on the Workbench-specific lines above.
