"""Run in CI right after `flutter create`. Adds what the generated platform folders lack:
internet/mic permissions, the app name, a fixed release signing key, and a nicer Windows window."""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
ok = True


def patch(path: pathlib.Path, old: str, new: str, label: str) -> None:
    global ok
    if not path.exists():
        print(f"skip {label}: {path} missing")
        return
    s = path.read_text(encoding="utf-8")
    if new in s:
        print(f"ok   {label} (already)")
        return
    if old not in s:
        print(f"FAIL {label}: pattern not found in {path.name}")
        ok = False
        return
    path.write_text(s.replace(old, new, 1), encoding="utf-8")
    print(f"ok   {label}")


# ---- Android ----
manifest = root / "android/app/src/main/AndroidManifest.xml"
perms = ('<uses-permission android:name="android.permission.INTERNET"/>\n'
         '    <uses-permission android:name="android.permission.RECORD_AUDIO"/>\n'
         '    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>\n'
         '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n'
         '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>\n'
         '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n'
         '    <uses-permission android:name="android.permission.ANSWER_PHONE_CALLS"/>\n'
         '    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n'
         '    <uses-permission android:name="android.permission.READ_CONTACTS"/>\n'
         '    <uses-permission android:name="android.permission.CALL_PHONE"/>\n'
         '    <queries>\n'
         '        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>\n'
         '        <intent><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent>\n'
         '        <intent><action android:name="android.intent.action.DIAL"/></intent>\n'
         '        <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>\n'
         '    </queries>\n'
         '    <application')
services = ('        <service android:name=".KeepAliveService" android:exported="false"'
            ' android:foregroundServiceType="microphone"/>\n'
            '        <service android:name=".NotifyListener" android:label="Tommy" android:exported="true"'
            ' android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">\n'
            '            <intent-filter><action android:name="android.service.notification.NotificationListenerService"/></intent-filter>\n'
            '        </service>\n'
            '        <service android:name=".HandsService" android:label="Tommy" android:exported="true"'
            ' android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">\n'
            '            <intent-filter><action android:name="android.accessibilityservice.AccessibilityService"/></intent-filter>\n'
            '            <meta-data android:name="android.accessibilityservice" android:resource="@xml/tommy_hands"/>\n'
            '        </service>\n'
            '    </application>')
patch(manifest, "<application", perms, "android permissions")
patch(manifest, "</application>", services, "android services")

# our native Kotlin code (background listening, calls & notifications, opening apps)
import shutil
kt_dir = root / "android/app/src/main/kotlin/com/tommyai/tommy"
if kt_dir.exists():
    for f in (root / "android_native").glob("*.kt"):
        shutil.copy(f, kt_dir / f.name)
        print(f"ok   copied {f.name}")
else:
    print(f"FAIL kotlin folder not found: {kt_dir}")
    ok = False
# accessibility config for Tommy's "hands"
xml_dir = root / "android/app/src/main/res/xml"
if manifest.exists():
    xml_dir.mkdir(parents=True, exist_ok=True)
    (xml_dir / "tommy_hands.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<accessibility-service xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:description="@string/tommy_hands_desc"\n'
        '    android:accessibilityEventTypes="typeWindowStateChanged|typeWindowContentChanged"\n'
        '    android:accessibilityFeedbackType="feedbackGeneric"\n'
        '    android:accessibilityFlags="flagReportViewIds|flagRetrieveInteractiveWindows"\n'
        '    android:canRetrieveWindowContent="true"\n'
        '    android:canPerformGestures="false"\n'
        '    android:notificationTimeout="200"/>\n', encoding="utf-8")
    values = root / "android/app/src/main/res/values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "tommy_strings.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <string name="tommy_hands_desc">Lets Tommy read the screen and press buttons when you ask by voice '
        '(for example pressing Send in WhatsApp). Nothing is collected or stored.</string>\n</resources>\n',
        encoding="utf-8")
    print("ok   accessibility config")
if manifest.exists():
    s = manifest.read_text(encoding="utf-8")
    s2 = re.sub(r'android:label="[^"]*"', 'android:label="Tommy"', s, count=1)
    manifest.write_text(s2, encoding="utf-8")
    print("ok   android label")

kts = root / "android/app/build.gradle.kts"
if kts.exists():
    patch(kts, "    buildTypes {", '''    signingConfigs {
        create("release") {
            val ks = System.getenv("TOMMY_KEYSTORE")
            if (ks != null && ks.isNotEmpty()) {
                storeFile = file(ks)
                storePassword = System.getenv("TOMMY_KEYSTORE_PASSWORD")
                keyAlias = "tommy"
                keyPassword = System.getenv("TOMMY_KEYSTORE_PASSWORD")
                storeType = "pkcs12"
            }
        }
    }

    buildTypes {''', "android signing config")
    patch(kts, 'signingConfig = signingConfigs.getByName("debug")',
          'signingConfig = if (System.getenv("TOMMY_KEYSTORE").isNullOrEmpty()) '
          'signingConfigs.getByName("debug") else signingConfigs.getByName("release")',
          "android release signing")
    s = kts.read_text(encoding="utf-8")
    s = re.sub(r"minSdk = flutter\.minSdkVersion", "minSdk = 23", s)
    kts.write_text(s, encoding="utf-8")
    print("ok   minSdk 23")
else:
    print("FAIL android/app/build.gradle.kts not found (Groovy template?)")
    ok = False

# ---- Windows ----
main_cpp = root / "windows/runner/main.cpp"
if main_cpp.exists():
    s = main_cpp.read_text(encoding="utf-8")
    s = s.replace('window.Create(L"tommy"', 'window.Create(L"Tommy"')
    s = re.sub(r"Win32Window::Size size\(\d+, \d+\);", "Win32Window::Size size(1280, 800);", s)
    main_cpp.write_text(s, encoding="utf-8")
    print("ok   windows title/size")

sys.exit(0 if ok else 1)
