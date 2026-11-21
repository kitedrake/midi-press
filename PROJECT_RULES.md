# MidiPress

- Build with `./build.sh` and test with `./test.sh`. Both need Xcode's toolchain (macOS 26 SDK); the Command Line
  Tools alone are not enough.
- omso Builder builds this repository from `omso-build.json` (build, tests, `--self-test`, copy into
  `/Applications/omso`). Keep that file working when build or test commands change.
- No remote yet; `main` is the working branch. Commit validated work locally; create a remote, push or install
  only when the user asks. Other projects' install and push permissions don't apply here.
- MidiPress ships under the Kitedrake label: the bundle ID is `com.kitedrake.midipress`. Changing it makes macOS
  forget the Accessibility permission and moves the saved defaults; don't change it without the user.
- Treat the repository as public: keep personal paths, account details, private material and real device or app
  setups out of commits, docs and screenshots (screenshots come from snapshot mode's made-up setup).
- Tests and the self-test never press real keys or switch apps: they use a recording `KeyOutput`. Running the app
  with real MIDI posts keys into whatever app is in front; only do that, or run mappings with Run Now, when the user
  asks. Never change the user's Accessibility, Input Monitoring or other privacy settings; the user grants them.
- The macro runner must leave no key held: a shortcut's key-up and modifier releases are always sent, even when a
  run is stopped. Keep Stop All interrupting long waits.
- `setup.json` is a compatibility contract: changing its shape needs a `Setup.currentSchema` bump and a conversion
  on load, with a test. Newer files are read but never overwritten; unreadable ones are moved aside, not lost.
- After UI changes, check snapshot-mode screenshots (light, dark, minimum size). Don't insert views above the
  mapping form or pin views with `safeAreaInset` in the window: on macOS 26 that blanks the sidebar. Banners go in
  overlays.
- In-app updates use Sparkle, pinned in `Package.swift`. Only release builds (`UPDATE_FEED_URL` and
  `UPDATE_PUBLIC_KEY` set) contain an updater; keep plain and omso Builder builds without one. `CFBundleVersion`
  is `VERSION`, which Sparkle compares, so bump `VERSION` for every release. Releases would go through `release.py`
  in the `software-site` repository once MidiPress is added there. Never commit signing keys.
