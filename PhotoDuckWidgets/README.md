# PhotoDuckWidgets — export Live Activity

This embedded WidgetKit extension supplies PhotoDuck's export Live Activity
for the Lock Screen and Dynamic Island. The shared activity attributes remain
in `iOSCleanup/Models/ExportActivityAttributes.swift` and are compiled into
both the app and this extension.

Notes
- The app already declares `NSSupportsLiveActivities` in its Info.plist.
- The extension deployment target is iOS 16.2 because the app uses
  `ActivityContent` for updates and final states.
- iOS caps background execution: if PhotoDuck leaves the foreground for more
  than ~30 s the export pauses (the Live Activity says so) and resumes when
  the app is reopened. This is an iOS platform limit, not an app choice.
