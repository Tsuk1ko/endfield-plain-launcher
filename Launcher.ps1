#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Run from an elevated 64-bit PowerShell console. Keep this console open until
Endfield.exe exits. An existing official Games.exe is reused when available;
otherwise a new suspended instance is created and never resumed.
Only the Games.exe instance created here is terminated during cleanup.
The native wait has no periodic wakeups. Ctrl+C may be deferred until the game
exits; forcibly closing the host may skip cleanup.
shortcut: waits for the directly created Endfield.exe only; revisit if the game
relaunches itself or delegates its lifetime to a different process.
#>
[CmdletBinding()]
param(
    [string] $LauncherRoot = '',
    [string] $GamePath = '',
    [string] $GameArgs = ''
)

function Get-LauncherInstall {
    $uninstallRoots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($registryRoot in $uninstallRoots) {
        foreach ($key in (Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
            $name = [string]$key.GetValue('DisplayName')
            if ($name -notmatch 'Hypergryph Launcher|^\u9e70\u89d2\u542f\u52a8\u5668$') { continue }
            $root = [string]$key.GetValue('InstallLocation')
            if ($root -and (Test-Path -LiteralPath (Join-Path $root 'Launcher.exe') -PathType Leaf)) {
                return [pscustomobject]@{ Root = $root; Version = [string]$key.GetValue('DisplayVersion') }
            }
        }
    }
    foreach ($key in (Get-ChildItem -LiteralPath 'HKCU:\Software\HyperGryph\Launcher' -ErrorAction SilentlyContinue)) {
        $root = [string]$key.GetValue('install_path')
        if ($root -and (Test-Path -LiteralPath (Join-Path $root 'Launcher.exe') -PathType Leaf)) {
            return [pscustomobject]@{ Root = $root; Version = $null }
        }
    }
    $protocol = Get-Item -LiteralPath 'Registry::HKEY_CLASSES_ROOT\hypergryphlauncher-abYeZZ16BPluCFyT\shell\open\command' -ErrorAction SilentlyContinue
    if ($null -ne $protocol) {
        $command = [string]$protocol.GetValue('')
        # Parse the registered path as data; never execute a registry command.
        if ($command -match '^\s*"([^"]+\\Launcher\.exe)"(?:\s|$)') {
            $launcher = $Matches[1]
            if (Test-Path -LiteralPath $launcher -PathType Leaf) {
                return [pscustomobject]@{ Root = (Split-Path -Parent $launcher); Version = $null }
            }
        }
    }
    throw 'Cannot locate Hypergryph Launcher in the registry. Specify -LauncherRoot.'
}

function Resolve-GamesExecutable {
    param([string] $Root, [string] $RegisteredVersion)
    $versions = @($RegisteredVersion)
    $launcher = Join-Path $Root 'Launcher.exe'
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        $info = (Get-Item -LiteralPath $launcher).VersionInfo
        $versions += '{0}.{1}.{2}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart
    }
    foreach ($version in $versions) {
        if ($version -notmatch '^\d+(\.\d+){1,3}$') { continue }
        $candidate = Join-Path $Root "$version\Games.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $candidates = foreach ($folder in (Get-ChildItem -LiteralPath $Root -Directory)) {
        $versionNumber = $null
        if ([version]::TryParse($folder.Name, [ref]$versionNumber)) {
            $candidate = Join-Path $folder.FullName 'Games.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                [pscustomobject]@{ Version = $versionNumber; Path = $candidate }
            }
        }
    }
    $latest = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $latest) { throw "No version directory containing Games.exe found under: $Root" }
    Write-Warning "No usable registered/file version; selecting directory version $($latest.Version)."
    return $latest.Path
}

function Get-MmkvCrc32 {
    param([byte[]] $Data, [int] $Offset, [int] $Count)
    [uint32] $crc = [uint32]::MaxValue
    for ($i = $Offset; $i -lt $Offset + $Count; $i++) {
        $crc = $crc -bxor $Data[$i]
        for ($bit = 0; $bit -lt 8; $bit++) {
            if ($crc -band 1) { $crc = ($crc -shr 1) -bxor [uint32]3988292384 }
            else { $crc = $crc -shr 1 }
        }
    }
    return $crc -bxor [uint32]::MaxValue
}

function Unprotect-MmkvData {
    param([byte[]] $Data, [byte[]] $Key, [byte[]] $IV)
    $aes = [Security.Cryptography.Aes]::Create()
    $encryptor = $null
    try {
        $aes.Mode = [Security.Cryptography.CipherMode]::ECB
        $aes.Padding = [Security.Cryptography.PaddingMode]::None
        $aes.Key = $Key
        $encryptor = $aes.CreateEncryptor()
        $plain = [byte[]]::new($Data.Length)
        $stream = [byte[]]::new(16)
        $feedback = [byte[]]$IV.Clone()
        # Implement CFB128 with AES blocks: .NET Framework's CFB support differs from modern .NET.
        for ($offset = 0; $offset -lt $Data.Length; $offset += 16) {
            $null = $encryptor.TransformBlock($feedback, 0, 16, $stream, 0)
            $count = [Math]::Min(16, $Data.Length - $offset)
            for ($i = 0; $i -lt $count; $i++) {
                $plain[$offset + $i] = $Data[$offset + $i] -bxor $stream[$i]
            }
            [Array]::Copy($Data, $offset, $feedback, 0, $count)
        }
        return , $plain
    }
    finally {
        if ($null -ne $encryptor) { $encryptor.Dispose() }
        $aes.Dispose()
    }
}

function Read-MmkvVarint {
    param([byte[]] $Data, [ref] $Position, [int] $Limit)
    [uint32] $value = 0
    for ($shift = 0; $shift -lt 35; $shift += 7) {
        if ($Position.Value -ge $Limit) { throw 'Truncated MMKV varint.' }
        $b = $Data[$Position.Value]
        $Position.Value++
        if ($shift -eq 28 -and $b -gt 15) { throw 'Invalid MMKV varint.' }
        $value = $value -bor ([uint32]($b -band 127) -shl $shift)
        if ($b -lt 128) { return $value }
    }
    throw 'Invalid MMKV varint.'
}

function Read-MmkvGamePaths {
    param([byte[]] $Data, [byte[]] $Metadata, [string] $Guid)
    if ($Data.Length -lt 4 -or $Metadata.Length -lt 32) { throw 'Truncated MMKV header.' }
    # shortcut: only metadata v3 is verified; add other versions when samples are available.
    if ([BitConverter]::ToUInt32($Metadata, 4) -ne 3) { throw 'Unsupported MMKV metadata version.' }
    $length = [BitConverter]::ToUInt32($Data, 0)
    if ($length -gt $Data.Length - 4 -or $length -ne [BitConverter]::ToUInt32($Metadata, 28)) {
        throw 'MMKV length mismatch.'
    }
    if ((Get-MmkvCrc32 -Data $Data -Offset 4 -Count $length) -ne [BitConverter]::ToUInt32($Metadata, 0)) {
        throw 'MMKV CRC mismatch; the launcher may be updating its cache.'
    }
    if (-not $Guid) { throw 'Missing launcher REG_GUID.' }
    if ($length -eq 0) { return }
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $hash = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Guid + '*B59C326D-A124-413B-AABC-0D98D8B41966*'))
        $key = [Text.Encoding]::ASCII.GetBytes(([BitConverter]::ToString($hash).Replace('-', '')).Substring(0, 16))
    }
    finally { $md5.Dispose() }
    $plain = Unprotect-MmkvData -Data $Data[4..(3 + $length)] -Key $key -IV $Metadata[12..27]
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $utf16 = [Text.UnicodeEncoding]::new($false, $false, $true)
    $paths = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $position = 0
    $null = Read-MmkvVarint -Data $plain -Position ([ref]$position) -Limit $length
    while ($position -lt $length) {
        $count = Read-MmkvVarint -Data $plain -Position ([ref]$position) -Limit $length
        if ($count -eq 0 -or $count -gt $length - $position) { throw 'Invalid MMKV key length.' }
        $name = $utf8.GetString($plain, $position, $count)
        if ($name.Contains([string][char]0)) { throw 'Invalid MMKV key.' }
        $position += $count
        $count = Read-MmkvVarint -Data $plain -Position ([ref]$position) -Limit $length
        if ($count -gt $length - $position) { throw 'Invalid MMKV value length.' }
        $end = $position + $count
        if ($name.StartsWith('game_install_path_', [StringComparison]::Ordinal)) {
            if ($count -eq 0) { $null = $paths.Remove($name) }
            else {
                $count = Read-MmkvVarint -Data $plain -Position ([ref]$position) -Limit $end
                if ($count -ne $end - $position -or $count % 2) { throw 'Invalid MMKV path length.' }
                $path = $utf16.GetString($plain, $position, $count).TrimEnd([char]0)
                if ($path.Contains([string][char]0) -or $path -notmatch '^(?:[a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
                    throw 'Invalid absolute MMKV game path.'
                }
                $paths[$name] = $path
            }
        }
        $position = $end
    }
    return $paths.Values
}

function Read-MmkvFile {
    param([string] $Path)
    # MMKV may keep a write handle open; length and CRC checks reject inconsistent snapshots.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $buffer = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($buffer)
        return , $buffer.ToArray()
    }
    finally {
        $buffer.Dispose()
        $stream.Dispose()
    }
}

function Get-CachedGameExecutable {
    $candidates = @(foreach ($entry in (Get-ChildItem -LiteralPath 'HKCU:\Software\HyperGryph\Launcher' -ErrorAction SilentlyContinue)) {
            $cache = Join-Path ([Environment]::GetFolderPath('UserProfile')) "AppData\LocalLow\HyperGryph\$($entry.PSChildName)\config\config_cache"
            if (-not (Test-Path -LiteralPath $cache -PathType Leaf)) { continue }
            try {
                if ($entry.GetValueKind('REG_GUID') -ne [Microsoft.Win32.RegistryValueKind]::String) {
                    throw 'Launcher REG_GUID is not a string.'
                }
                $paths = Read-MmkvGamePaths -Data (Read-MmkvFile $cache) `
                    -Metadata (Read-MmkvFile "$cache.crc") -Guid ($entry.GetValue('REG_GUID'))
                foreach ($path in $paths) {
                    $candidate = Join-Path $path 'Endfield.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
                }
            }
            catch { Write-Warning "Cannot read launcher cache '$cache': $($_.Exception.Message)" }
        })
    $candidates = @($candidates | Sort-Object -Unique)
    if ($candidates.Count -gt 1) {
        throw "Multiple cached Endfield.exe paths found: $($candidates -join '; '). Specify -GamePath."
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }
}

function Resolve-GameExecutable {
    param([string] $Root)
    $cached = Get-CachedGameExecutable
    if ($cached) { return $cached }
    $games = Join-Path $Root 'games'
    foreach ($name in @('Arknights Endfield', 'Endfield Game')) {
        $candidate = Join-Path $games "$name\Endfield.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "Endfield.exe not found in launcher cache or default directories under: $games . Specify -GamePath."
}

function Resolve-EndfieldPaths {
    param([string] $LauncherRoot = '', [string] $GamePath = '')
    $registeredVersion = $null
    if (-not $LauncherRoot) {
        $install = Get-LauncherInstall
        $LauncherRoot = $install.Root
        $registeredVersion = $install.Version
    }
    if (-not $LauncherRoot -or -not (Test-Path -LiteralPath $LauncherRoot -PathType Container)) {
        throw "Launcher root directory not found: $LauncherRoot"
    }
    $root = (Resolve-Path -LiteralPath $LauncherRoot).ProviderPath
    $GamesPath = Resolve-GamesExecutable -Root $root -RegisteredVersion $registeredVersion
    if ($GamePath) {
        if (Test-Path -LiteralPath $GamePath -PathType Container) { $GamePath = Join-Path $GamePath 'Endfield.exe' }
        if (-not (Test-Path -LiteralPath $GamePath -PathType Leaf)) {
            throw "Executable not found: $GamePath . Check -GamePath."
        }
    }
    else {
        $GamePath = Resolve-GameExecutable -Root $root
    }
    if (-not (Test-Path -LiteralPath $GamesPath -PathType Leaf)) {
        throw "Executable not found: $GamesPath . Check the installation under -LauncherRoot."
    }
    return [pscustomobject]@{
        Games = (Resolve-Path -LiteralPath $GamesPath).ProviderPath
        Game  = (Resolve-Path -LiteralPath $GamePath).ProviderPath
        Root  = [IO.Path]::GetFullPath($root)
    }
}

$ErrorActionPreference = 'Stop'
$instanceMutex = [System.Threading.Mutex]::new($false, 'Local\Tsuk1ko.EndfieldPlainLauncher')
$ownsInstanceMutex = $false
try {
    try {
        $ownsInstanceMutex = $instanceMutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # WaitOne grants ownership when the previous owner terminated unexpectedly.
        $ownsInstanceMutex = $true
    }
    if (-not $ownsInstanceMutex) { return }

    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell.' }
    $paths = Resolve-EndfieldPaths -LauncherRoot $LauncherRoot -GamePath $GamePath
    Write-Host "Games.exe: $($paths.Games)"
    Write-Host "Endfield.exe: $($paths.Game)"

    $nativeSource = @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class EndfieldParentLaunch
{
    const uint CREATE_SUSPENDED = 0x00000004;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT = 258;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public uint cb;
        public string lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize;
        public uint dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public ushort wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public uint dwProcessId, dwThreadId;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", ExactSpelling = true,
        CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateProcess(string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint flags, IntPtr environment, string currentDirectory,
        ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInfo);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", ExactSpelling = true,
        CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateProcessExtended(string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint flags, IntPtr environment, string currentDirectory,
        ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count,
        uint flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags,
        IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", ExactSpelling = true,
        CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool QueryFullProcessImageName(IntPtr process, uint flags,
        StringBuilder path, ref uint length);

    static Win32Exception Error(string operation)
    {
        int code = Marshal.GetLastWin32Error();
        return new Win32Exception(code, operation + " failed (Win32 " + code + "): " +
            new Win32Exception(code).Message);
    }

    // Reject a layout mismatch before passing structures to Windows.
    public static void ValidateLayout()
    {
        if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(STARTUPINFO)) != 104 ||
            Marshal.SizeOf(typeof(STARTUPINFOEX)) != 112 ||
            Marshal.SizeOf(typeof(PROCESS_INFORMATION)) != 24)
            throw new InvalidOperationException("Unexpected Win64 structure layout.");
    }

    public static PROCESS_INFORMATION CreateSuspendedParent(string path)
    {
        STARTUPINFO si = new STARTUPINFO();
        si.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        if (!CreateProcess(path, new StringBuilder("\"" + path + "\""),
            IntPtr.Zero, IntPtr.Zero, false, CREATE_SUSPENDED, IntPtr.Zero,
            Path.GetDirectoryName(path), ref si, out pi))
            throw Error("Create suspended Games.exe");
        return pi;
    }

    public static bool IsLauncherImage(string image, string selectedPath, string root)
    {
        if (String.Equals(image, selectedPath, StringComparison.OrdinalIgnoreCase)) return true;
        if (!String.Equals(Path.GetFileName(image), "Games.exe", StringComparison.OrdinalIgnoreCase)) return false;
        string directory = Path.GetDirectoryName(image);
        Version version;
        return Version.TryParse(Path.GetFileName(directory), out version) &&
            String.Equals(Path.GetDirectoryName(directory).TrimEnd('\\'), root.TrimEnd('\\'),
                StringComparison.OrdinalIgnoreCase);
    }

    public static PROCESS_INFORMATION FindExistingParent(string selectedPath, string root)
    {
        int sessionId;
        using (Process current = Process.GetCurrentProcess()) sessionId = current.SessionId;
        Process[] processes = Process.GetProcessesByName("Games");
        try
        {
            foreach (Process process in processes)
            {
                try { if (process.SessionId != sessionId) continue; }
                catch (InvalidOperationException) { continue; }
                // Query first, then acquire CREATE_PROCESS only for a matching image.
                IntPtr handle = OpenProcess(0x00101000, false, (uint)process.Id);
                if (handle == IntPtr.Zero) continue;
                try
                {
                    StringBuilder path = new StringBuilder(32768);
                    uint length = (uint)path.Capacity;
                    if (!QueryFullProcessImageName(handle, 0, path, ref length)) continue;
                    if (!IsLauncherImage(path.ToString(), selectedPath, root) || HasExited(handle, 0)) continue;
                    IntPtr parentHandle = OpenProcess(0x00101080, false, (uint)process.Id);
                    if (parentHandle == IntPtr.Zero) throw Error("Open existing Games.exe as parent");
                    // Recheck the acquired handle so exit/PID reuse cannot select a different image.
                    try
                    {
                        length = (uint)path.Capacity;
                        if (!QueryFullProcessImageName(parentHandle, 0, path, ref length) ||
                            !IsLauncherImage(path.ToString(), selectedPath, root) || HasExited(parentHandle, 0))
                            continue;
                        PROCESS_INFORMATION pi = new PROCESS_INFORMATION();
                        pi.hProcess = parentHandle;
                        pi.dwProcessId = (uint)process.Id;
                        parentHandle = IntPtr.Zero;
                        return pi;
                    }
                    finally { if (parentHandle != IntPtr.Zero) CloseHandle(parentHandle); }
                }
                finally { CloseHandle(handle); }
            }
        }
        finally { foreach (Process process in processes) process.Dispose(); }
        return new PROCESS_INFORMATION();
    }

    public static PROCESS_INFORMATION CreateGame(string path, IntPtr parent, string gameArgs)
    {
        IntPtr bytes = IntPtr.Zero;
        IntPtr list = IntPtr.Zero;
        IntPtr parentValue = IntPtr.Zero;
        bool initialized = false;
        try
        {
            // The sizing call is expected to fail with ERROR_INSUFFICIENT_BUFFER.
            bool sized = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
            int sizingError = Marshal.GetLastWin32Error();
            if (sized || sizingError != 122 || bytes.ToInt64() <= 0)
                throw new Win32Exception(sizingError, "Cannot size process attribute list.");
            list = Marshal.AllocHGlobal(bytes);
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref bytes))
                throw Error("Initialize process attribute list");
            initialized = true;
            parentValue = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(parentValue, parent);
            if (!UpdateProcThreadAttribute(list, 0, new IntPtr(0x00020000),
                parentValue, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw Error("Set PROC_THREAD_ATTRIBUTE_PARENT_PROCESS");

            STARTUPINFOEX si = new STARTUPINFOEX();
            si.StartupInfo.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.lpAttributeList = list;
            PROCESS_INFORMATION pi;
            StringBuilder commandLine = new StringBuilder("\"" + path + "\"");
            if (!String.IsNullOrEmpty(gameArgs)) commandLine.Append(' ').Append(gameArgs);
            if (!CreateProcessExtended(path, commandLine,
                IntPtr.Zero, IntPtr.Zero, false, EXTENDED_STARTUPINFO_PRESENT,
                IntPtr.Zero, Path.GetDirectoryName(path), ref si, out pi))
                throw Error("Create Endfield.exe with specified parent");
            return pi;
        }
        finally
        {
            if (initialized) DeleteProcThreadAttributeList(list);
            if (parentValue != IntPtr.Zero) Marshal.FreeHGlobal(parentValue);
            if (list != IntPtr.Zero) Marshal.FreeHGlobal(list);
        }
    }

    public static bool HasExited(IntPtr process, uint timeoutMilliseconds)
    {
        uint result = WaitForSingleObject(process, timeoutMilliseconds);
        if (result == WAIT_OBJECT_0) return true;
        if (result == WAIT_TIMEOUT) return false;
        throw Error("Wait for process");
    }

    public static uint ExitCode(IntPtr process)
    {
        uint code;
        if (!GetExitCodeProcess(process, out code)) throw Error("Read game exit code");
        return code;
    }

    public static void StopParent(PROCESS_INFORMATION parent)
    {
        if (parent.hProcess == IntPtr.Zero || HasExited(parent.hProcess, 0)) return;
        if (!TerminateProcess(parent.hProcess, 0))
        {
            Win32Exception error = Error("Terminate owned Games.exe PID " + parent.dwProcessId);
            if (!HasExited(parent.hProcess, 0)) throw error;
        }
        if (!HasExited(parent.hProcess, 5000))
            throw new TimeoutException("Games.exe termination timed out. PID " + parent.dwProcessId);
    }

    public static void Close(PROCESS_INFORMATION process)
    {
        if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
        if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
    }
}
'@

    if (-not ('EndfieldParentLaunch' -as [type])) {
        Add-Type -TypeDefinition $nativeSource
    }
    [EndfieldParentLaunch]::ValidateLayout()

    $parentInfo = New-Object 'EndfieldParentLaunch+PROCESS_INFORMATION'
    $gameInfo = New-Object 'EndfieldParentLaunch+PROCESS_INFORMATION'
    $ownsParent = $false
    try {
        $parentInfo = [EndfieldParentLaunch]::FindExistingParent($paths.Games, $paths.Root)
        if ($parentInfo.hProcess -eq [IntPtr]::Zero) {
            $parentInfo = [EndfieldParentLaunch]::CreateSuspendedParent($paths.Games)
            $ownsParent = $true
            Write-Host "Created suspended Games.exe PID: $($parentInfo.dwProcessId)"
        }
        else {
            Write-Host "Reusing Games.exe PID: $($parentInfo.dwProcessId); it will NOT be terminated."
        }
        $gameInfo = [EndfieldParentLaunch]::CreateGame($paths.Game, $parentInfo.hProcess, $GameArgs)
        Write-Host "Endfield.exe PID: $($gameInfo.dwProcessId); parent PID: $($parentInfo.dwProcessId)"
        Write-Host 'Waiting for Endfield.exe to exit. Keep this console open.'
        # INFINITE waits on the kernel process object without a recurring timer.
        $null = [EndfieldParentLaunch]::HasExited($gameInfo.hProcess, [uint32]::MaxValue)
        $gameExitCode = [EndfieldParentLaunch]::ExitCode($gameInfo.hProcess)
        Write-Host ('Endfield.exe exited: {0} (0x{0:X8})' -f $gameExitCode)
    }
    finally {
        try {
            if ($ownsParent) { [EndfieldParentLaunch]::StopParent($parentInfo) }
        }
        finally {
            [EndfieldParentLaunch]::Close($gameInfo)
            [EndfieldParentLaunch]::Close($parentInfo)
        }
    }
}
finally {
    try {
        if ($ownsInstanceMutex) { $instanceMutex.ReleaseMutex() }
    }
    finally {
        $instanceMutex.Dispose()
    }
}
