# Stream

Running work log, newest first. Every change gets an entry: timestamp · what · why · where to
pick up if the session is interrupted. `HANDOFF.md` (when it exists) is the polished snapshot;
this file is the play-by-play.

---

## 2026-08-14 — 2.1.1: fix "always hidden" section doing nothing (issue #2)

**What.** `StatusBarController.btnAlwaysHiddenLength` was a *stored* property whose initializer
read `Preferences.alwaysHiddenSectionEnabled`. Stored-property initializers run once, when the
controller is constructed at launch. The preference defaults to `false`, so the width was frozen
at `0` for the whole process lifetime. Ticking "Enable always hidden section" in Preferences did
post `.alwayHideToggle`, and `toggleStatusBarIfNeeded()` did create the `NSStatusItem` — but with
`withLength: 0`, which renders nothing. The separator only showed up after a relaunch.

Changed `btnAlwaysHiddenLength` to a computed property so it tracks the preference live, and made
`toggleStatusBarIfNeeded()` re-apply the width after creating the item — picking the collapsed
width when `Preferences.areSeparatorsHidden` is already true, so the section can hide icons
immediately instead of needing two separator toggles.

`btnAlwaysHiddenEnableExpandCollapseLength` stays stored (it is screen-width derived) but its
initializer no longer reads the preference; `updateCollapsedLengths()` owns it and runs from both
`init()` and `toggleStatusBarIfNeeded()`.

**Also in this version.** The Xcode project now carries `DEVELOPMENT_TEAM = 485WH9DHS4` and an
`Apple Development` signing identity so local Xcode builds sign against Shelby's developer
account. Verified this does *not* leak into release signing:

```
xcodebuild ... CODE_SIGN_IDENTITY="Developer ID Application: Shelby Denike (485WH9DHS4)" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=485WH9DHS4 -showBuildSettings
  → CODE_SIGN_IDENTITY = Developer ID Application: Shelby Denike (485WH9DHS4)
```

Command-line build settings override the project-level `CODE_SIGN_IDENTITY[sdk=macosx*]`
conditional, which is exactly what `scripts/release.sh` relies on.

**Verified.** `xcodebuild -scheme "Hidden Bar" -configuration Debug CODE_SIGNING_ALLOWED=NO build`
→ `** BUILD SUCCEEDED **`. Not yet exercised by hand in a running menu bar — worth a manual smoke
test (toggle the checkbox with the app running and confirm a second separator appears without a
relaunch) before or just after the release lands.

**If interrupted here.** Version is bumped to `2.1.1` / build `22` in `project.pbxproj` and
`CHANGELOG.md` has its `2.1.1` section. Remaining: commit, tag `v2.1.1`, `git push origin main
--tags`. The `Release` workflow takes the tag from there — it re-derives the version from
`MARKETING_VERSION`, builds, signs with Developer ID, notarizes, staples, publishes
`HiddenBarRevived-2.1.1.zip`, and pushes the new `version`/`sha256` to
`sdenike/homebrew-tap`'s `Casks/hidden-revived.rb`. Then reply on issue #2 and close it.
