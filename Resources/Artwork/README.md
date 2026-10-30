# App icon artwork

`AppIcon.png` is the final transparent artwork supplied and approved by the user.
The artwork edit used the built-in image generator with this request: remove the
right-hand title-bar controls from the floating windows, preserve their left-hand
traffic lights and composition, and remove the surrounding glow/background.
The user's uploaded cutout is the selected final source.

Regenerate from the project root:

```sh
xcrun swift -module-cache-path build/ModuleCache scripts/make-app-icon.swift
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

Representations below 64 physical pixels use monochrome OS marks in generic
windows. Representations of 64 pixels and above use the approved full artwork.
The packaged `Resources/AppIcon.icns` is shared by both build paths, the Dock,
standard About panel and the registered `.asvm` document type.
