import SwiftUI

/// Settings › Desktop & Lock Screen: how wallpapers meet the macOS desktop picture, Mission
/// Control, the lock screen and the screen saver.
struct DesktopSettingsSection: View {
  private static let desktop = SettingsItem.Group("desktop", title: "Desktop")
  private static let lockScreen = SettingsItem.Group("lock-screen", title: "Lock screen")
  private static let screenSaver = SettingsItem.Group("screen-saver", title: "Screen saver")

  static let writeDesktopPicture = SettingsItem(
    id: "desktop.write-desktop-picture", section: .desktop, group: desktop,
    title: "Use the wallpaper as the macOS desktop picture",
    note:
      "Mission Control and the moment before a wallpaper loads show a still frame of the wallpaper. Turn this off to leave macOS’s own wallpaper settings alone; your own picture comes back at once.",
    keywords: [
      "Animate lock screen sets the desktop picture itself, so this cannot be changed while it is on."
    ])
  static let refreshMissionControl = SettingsItem(
    id: "desktop.refresh-mission-control", section: .desktop, group: desktop,
    title: "Update the Mission Control picture every 5 minutes",
    note:
      "Mission Control shows a still picture of the wallpaper, retaken when it starts, changes or resumes. This also retakes it while it plays. Not used while the lock screen is animated."
  )
  static let keepWindowsOnClick = SettingsItem(
    id: "desktop.keep-windows-on-click", section: .desktop, group: desktop,
    title: "Keep windows in place when clicking the wallpaper",
    note:
      "Turns off macOS’s “Click wallpaper to reveal desktop” so clicks reach interactive wallpapers."
  )
  static let livePropertyEdits = SettingsItem(
    id: "desktop.live-property-edits", section: .desktop, group: desktop,
    title: "Show property edits on the desktop as I make them",
    note:
      "While you edit a wallpaper’s properties, your displays follow each change before you press Apply changes, and Revert puts the saved look back. Pictures and options that switch an effect on or off still wait for Apply changes. The lock screen and the Mission Control picture keep the saved look until you apply."
  )

  static let lockScreenSwitch = SettingsItem(
    id: "desktop.lock-screen", section: .desktop, group: lockScreen, title: "Animate lock screen",
    note: "Experimental")
  static let lockScreenStatus = SettingsItem(
    id: "desktop.lock-screen-status", section: .desktop, group: lockScreen,
    title: "Lock screen status", keywords: ["Retry"])
  static let lockScreenContext = SettingsItem(
    id: "desktop.lock-screen-context", section: .desktop, group: lockScreen,
    title: "Compatibility & permissions")

  static let screenSaverSwitch = SettingsItem(
    id: "desktop.screen-saver", section: .desktop, group: screenSaver,
    title: "Use wallpaper as screen saver", note: "Experimental")
  static let screenSaverStatus = SettingsItem(
    id: "desktop.screen-saver-status", section: .desktop, group: screenSaver,
    title: "Screen saver status", keywords: ["Retry"])
  static let screenSaverContext = SettingsItem(
    id: "desktop.screen-saver-context", section: .desktop, group: screenSaver,
    title: "Compatibility & permissions")

  static let items = [
    writeDesktopPicture, refreshMissionControl, keepWindowsOnClick, livePropertyEdits,
    lockScreenSwitch, lockScreenStatus, lockScreenContext, screenSaverSwitch, screenSaverStatus,
    screenSaverContext,
  ]

  @Environment(PanelController.self) private var controller

  var body: some View {
    let desktop = controller.desktopSettings
    SettingsPage(.desktop) {
      SettingsUnavailableNotice()
      SettingsGroup(Self.desktop, in: .desktop) {
        SettingsRow(Self.writeDesktopPicture, note: desktop.lockedNote) {
          SettingsSwitchControl(key: .writeDesktopPicture)
        }
        SettingsRow(Self.refreshMissionControl) {
          SettingsSwitchControl(key: .refreshDesktopPicture)
        }
        SettingsRow(Self.keepWindowsOnClick) {
          SettingsSwitchControl(key: .keepWindowsOnWallpaperClick)
        }
        SettingsRow(Self.livePropertyEdits) { SettingsSwitchControl(key: .livePropertyEdits) }
      }
      SettingsGroup(Self.lockScreen, in: .desktop) {
        SettingsRow(Self.lockScreenSwitch) { SettingsSwitchControl(key: .lockScreenEnabled) }
        statusRow(Self.lockScreenStatus, controller.lockScreenState)
        if search.shows(Self.lockScreenStatus), let error = controller.lockScreenState.error {
          SettingsErrorLine(message: error)
        }
        SettingsDisclosure(Self.lockScreenContext) {
          SettingsProse {
            Text(
              "Lock screen animation uses private macOS APIs and may stop working after a macOS update. While it is on, the app takes over only the Desktop wallpaper selection on displays with an applied scene or video wallpaper, and reloads the macOS wallpaper service. The screen saver is a separate choice below. Turning this off restores the Desktop choices; quitting restores all choices the app changed and keeps other wallpaper changes."
            )
            Text(
              "It keeps separate copies of wallpaper files, which uses extra disk space, and may not render on every macOS version. Pause and battery settings still apply."
            )
          }
        }
      }
      SettingsGroup(Self.screenSaver, in: .desktop) {
        SettingsRow(Self.screenSaverSwitch) { SettingsSwitchControl(key: .screenSaverEnabled) }
        statusRow(Self.screenSaverStatus, controller.screenSaverState)
        if search.shows(Self.screenSaverStatus), let error = controller.screenSaverState.error {
          SettingsErrorLine(message: error)
        }
        SettingsDisclosure(Self.screenSaverContext) {
          SettingsProse {
            Text(
              "Requires macOS 26 or later. Uses each display’s applied wallpaper as its screen saver, including scenes, videos, web wallpapers and still images. This experimental feature uses private macOS APIs and may stop working after an update."
            )
            Text(
              "The screen saver choice is independent of lock screen animation. It changes only the Idle wallpaper selection and reloads the macOS wallpaper service. Turning it off restores the previous screen saver without changing the Desktop selection, and keeps screen saver changes made elsewhere. Pause and battery settings still apply."
            )
          }
        }
      }
    }
    .onAppear { controller.refreshSystemReadings() }
  }

  private var search: SettingsSearch { controller.settings.search }

  /// The status the service reports, with Retry beside it while it reports a failure. Retry waits
  /// for the service to finish, and for the Mac, so it is never pressed twice.
  private func statusRow(_ item: SettingsItem, _ state: LockScreenState) -> some View {
    let key = state.kind == .lockScreen ? "lockScreenRetry" : "screenSaverRetry"
    return SettingsRow(item) {
      SettingsStatusText(text: state.statusText) {
        if state.error != nil {
          SettingsActionButton(
            "Retry",
            isDisabled: !state.canRetry || controller.settings.isLocked(key, whileRunning: true)
          ) {
            controller.settings.perform(key) {
              if state.kind == .lockScreen {
                try await controller.retryLockScreen()
              } else {
                try await controller.retryScreenSaver()
              }
            }
          }
        }
      }
    }
  }

}
