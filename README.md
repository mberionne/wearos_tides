# Tides

An application for WearOS watches to display the ocean tide.

The application is intentionally very simple:
 * It can only use the current location of the watch,
 * It only display the data for the day.

Normally the tide chart of the next day is similar to the previous one,
so the chart of the current day is sufficient and helps keeping the UX of
the application simple and quick to look at.

It is possible to double tap on the tide chart to force a refresh.

# Compile the app

To compile it, run the following command in the terminal:
```
 $ flutter build apk
```

The APK is generated in the following path: `build/app/outputs/flutter-apk/app-release.apk`. The APK can be downloaded and installed on the device.

The app version is defined directly in the gradle file in `android/app/build.gradle` (and not taken from `local.properties`).
