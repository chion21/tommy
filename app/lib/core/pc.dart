import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Windows PC control through PowerShell: windows (list / focus / close), keyboard, mouse, screenshots,
/// commands and terminal, media keys. Everything here does nothing on other platforms.
class Pc {
  static bool get on => Platform.isWindows;

  static String _q(String s) => "'${s.replaceAll("'", "''")}'"; // PowerShell single-quoted string

  /// Runs a PowerShell script and returns (exit code, output).
  static Future<(int, String)> ps(String script, {Duration timeout = const Duration(seconds: 60)}) async {
    final full = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; \$ProgressPreference="SilentlyContinue"; $script';
    final encoded = base64Encode(Uint8List.fromList(
        full.codeUnits.expand((c) => [c & 0xff, c >> 8]).toList())); // -EncodedCommand wants UTF-16LE
    try {
      final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
              stdoutEncoding: utf8, stderrEncoding: utf8)
          .timeout(timeout);
      final out = '${r.stdout}${(r.stderr as String).trim().isEmpty ? '' : '\n${r.stderr}'}'.trim();
      return (r.exitCode, out);
    } catch (e) {
      return (-1, '$e');
    }
  }

  // ---------- windows ----------
  static Future<List<Map<String, dynamic>>> windows() async {
    final (_, out) = await ps(r"Get-Process | Where-Object { $_.MainWindowTitle -ne '' } | "
        r'Select-Object Id, ProcessName, MainWindowTitle | ConvertTo-Json -Compress');
    try {
      final j = jsonDecode(out);
      final list = j is List ? j : [j];
      return [
        for (final w in list)
          {'id': w['Id'], 'app': w['ProcessName'], 'title': w['MainWindowTitle']}
      ];
    } catch (_) {
      return [];
    }
  }

  static String _match(String what) => '\$w = ${_q(what.toLowerCase())}; '
      r"$ps = Get-Process | Where-Object { $_.MainWindowTitle -ne '' -and $_.ProcessName -ne 'tommy' -and "
      r'($_.MainWindowTitle.ToLower().Contains($w) -or $_.ProcessName.ToLower().Contains($w)) }; ';

  /// Closes windows whose title or app name contains [what]. Returns the closed titles.
  static Future<List<String>> closeWindow(String what, {bool force = false}) async {
    if (what.trim().isEmpty) return [];
    final (_, out) = await ps('${_match(what)}'
        r'foreach ($p in $ps) { $t = $p.MainWindowTitle; '
        '${force ? r'Stop-Process -Id $p.Id -Force' : r'if (-not $p.CloseMainWindow()) { Stop-Process -Id $p.Id }'}; '
        r'Write-Output $t }');
    return out.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  /// Brings a window to the front. Returns its title or ''.
  static Future<String> focusWindow(String what) async {
    final (_, out) = await ps('${_match(what)}'
        r'$p = $ps | Select-Object -First 1; if ($p) { $s = New-Object -ComObject WScript.Shell; '
        r'[void]$s.AppActivate($p.Id); Start-Sleep -Milliseconds 300; Write-Output $p.MainWindowTitle }');
    return out.trim();
  }

  // ---------- keyboard / mouse ----------
  /// Types any text (also Bangla) into the window in front, via the clipboard. [enter] presses Enter after.
  static Future<bool> typeText(String text, {bool enter = false}) async {
    final (code, _) = await ps('Set-Clipboard -Value ${_q(text)}; Start-Sleep -Milliseconds 150; '
        r'$s = New-Object -ComObject WScript.Shell; $s.SendKeys("^v"); '
        '${enter ? r'Start-Sleep -Milliseconds 250; $s.SendKeys("{ENTER}")' : ''}');
    return code == 0;
  }

  /// Key combination in SendKeys notation: ^ = Ctrl, % = Alt, + = Shift, {ENTER}, {TAB}, {ESC}, {F4}…
  static Future<bool> pressKeys(String keys) async {
    final (code, _) = await ps(r'$s = New-Object -ComObject WScript.Shell; $s.SendKeys(' '${_q(keys)})');
    return code == 0;
  }

  static const _mouse = r'''
Add-Type @"
using System; using System.Runtime.InteropServices;
public class TommyMouse {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
}
"@
Add-Type -AssemblyName System.Windows.Forms
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
''';

  /// Clicks at a point given in 0..1000 screen coordinates (from [screenshot] + Brain.locate).
  static Future<bool> clickAt(int nx, int ny, {bool double = false}) async {
    final (code, _) = await ps('$_mouse'
        '\$x = [int](\$b.Left + \$b.Width * $nx / 1000); \$y = [int](\$b.Top + \$b.Height * $ny / 1000); '
        r'[TommyMouse]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 80; '
        r'[TommyMouse]::mouse_event(2,0,0,0,[IntPtr]::Zero); [TommyMouse]::mouse_event(4,0,0,0,[IntPtr]::Zero); '
        '${double ? r'Start-Sleep -Milliseconds 90; [TommyMouse]::mouse_event(2,0,0,0,[IntPtr]::Zero); [TommyMouse]::mouse_event(4,0,0,0,[IntPtr]::Zero)' : ''}');
    return code == 0;
  }

  /// Screenshot of all screens as JPEG (scaled down to max 1600 px wide).
  static Future<Uint8List?> screenshot() async {
    final path = '${Directory.systemTemp.path}\\tommy_screen.jpg';
    final (code, _) = await ps('Add-Type -AssemblyName System.Windows.Forms, System.Drawing; '
        r'$b = [System.Windows.Forms.SystemInformation]::VirtualScreen; '
        r'$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; '
        r'$g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size); '
        r'$w = [Math]::Min(1600, $b.Width); $h = [int]($b.Height * $w / $b.Width); '
        r'$small = New-Object System.Drawing.Bitmap $bmp, $w, $h; '
        '\$small.Save(${_q(path)}, [System.Drawing.Imaging.ImageFormat]::Jpeg)');
    final f = File(path);
    if (code != 0 || !await f.exists()) return null;
    return f.readAsBytes();
  }

  /// Media / volume keys (works for YouTube in the browser, Spotify, etc.).
  static Future<bool> media(String action) async {
    const vk = {'pause': 179, 'play': 179, 'stop': 178, 'next': 176, 'previous': 177,
        'mute': 173, 'unmute': 173, 'volume_down': 174, 'volume_up': 175};
    final k = vk[action];
    if (k == null) return false;
    final times = action.startsWith('volume') ? 5 : 1;
    final (code, _) = await ps(r'$s = New-Object -ComObject WScript.Shell; '
        '1..$times | ForEach-Object { \$s.SendKeys([char]$k) }');
    return code == 0;
  }

  // ---------- commands ----------
  static final _risky = RegExp(
      r'\b(remove-item|rm|del|erase|rmdir|rd|format|diskpart|clear-disk|stop-computer|restart-computer|shutdown|'
      r'reg\s+delete|remove-itemproperty|set-executionpolicy|uninstall|cipher|bcdedit|takeown|icacls|net\s+user|'
      r'invoke-webrequest|iwr|curl|wget|start-bitstransfer|iex|invoke-expression)\b',
      caseSensitive: false);
  static bool risky(String cmd) => _risky.hasMatch(cmd);

  /// Runs a PowerShell command hidden and returns its output.
  static Future<(int, String)> run(String command) => ps(command, timeout: const Duration(seconds: 90));

  /// Opens a visible terminal window (PowerShell), optionally running [command] in it.
  static Future<bool> openTerminal(String command) async {
    try {
      final args = command.trim().isEmpty ? ['/c', 'start', 'powershell', '-NoExit'] : ['/c', 'start', 'powershell', '-NoExit', '-Command', command];
      await Process.start('cmd', args, mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- clipboard ----------
  static Future<bool> setClipboard(String text) async => (await ps('Set-Clipboard -Value ${_q(text)}')).$1 == 0;
}
