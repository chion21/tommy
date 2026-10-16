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
         '    <queries><intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent></queries>\n'
         '    <application')
patch(manifest, "<application", perms, "android permissions")
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
