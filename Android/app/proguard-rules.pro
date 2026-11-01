# Keep Xposed entry points — loaded only via assets/xposed_init (reflection).
# R8 would otherwise strip them from the release APK.
-keep class com.airsend.xposed.** { *; }
-keep class * implements de.robv.android.xposed.IXposedHookLoadPackage { *; }
-keep class * implements de.robv.android.xposed.IXposedHookZygoteInit { *; }
-keep class * implements de.robv.android.xposed.IXposedHookInitPackageResources { *; }
-keep class * implements de.robv.android.xposed.IXposedInit { *; }
-dontwarn de.robv.android.xposed.**
