WhisperCaption — first-launch guide
====================================

WhisperCaption is signed by a free Apple Personal Team (no $99/yr fee to
Apple, no notarization metadata in Apple's logs). macOS Gatekeeper blocks
it on first launch and shows the dialog:

   "Apple could not verify "WhisperCaption.app" is free of malware..."

Click Done. Then follow these steps once:

   1. Drag WhisperCaption to Applications (use the arrow in this window).
   2. Open  System Settings → Privacy & Security.
   3. Scroll all the way to the bottom. You will see a line:
          "WhisperCaption.app was blocked to protect your Mac."
   4. Click  Open Anyway.
   5. Confirm with Touch ID, Apple Watch, or your password.
   6. macOS remembers this choice forever. Future launches work normally
      with a double-click like any other app.


Prefer no Gatekeeper friction at all?
======================================

Build from source instead. Your local build is signed under your own
Apple ID, so macOS opens it silently with no warnings:

   git clone https://github.com/albond/WhisperCaption.git
   open WhisperCaption/WhisperCaption.xcodeproj
   # in Xcode: hit Cmd+R

This is the recommended path if you want zero trust in someone else's
build. Source code is public; every commit goes through CI.


Verify this binary before granting Microphone / Screen Recording
=================================================================

   codesign -dvvv /Applications/WhisperCaption.app 2>&1 | grep '^Authority'

Expected first line:

   Apple Development: albond.dev@proton.me (...)

Anything else means the binary was re-signed somewhere along the way.
Don't trust it. Open an issue:
   https://github.com/albond/WhisperCaption/issues


Source code, docs, release history:
   https://github.com/albond/WhisperCaption
