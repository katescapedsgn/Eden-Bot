# Eden app icon

The local builder requires `assets/branding/Eden.icns`. It copies those bytes to `Eden.app/Contents/Resources/Eden.icns` and sets `CFBundleIconFile` to `Eden.icns`. Missing or invalid icon files stop the build.

`assets/branding/Eden.png` is the original PNG source asset. The builder does not convert it. The original `assets/Mochi.icns` remains untouched as a backup and is not used for new Eden builds.

This icon affects Finder, Dock, and the app switcher. It does not change the lavender cat sprites or animations.
