# FFRS_QoL item carry limit patcher.
# The game hardcodes 99 as the per-item carry limit. This rewrites those spots in the running
# game's memory (never the exe on disk). Limit 99 restores the original code.
# Started by the mod (Scripts/main.lua) at game start and whenever ItemLimit changes.
# With -BpFuncs it instead patches 99 constants in the shop buy dialog's Blueprint bytecode
# (main.lua passes "<UFunction address hex>@<bytecode offset>,..." once that class is loaded).
param([int]$Limit = 99, [string]$Out = "", [string]$BpFuncs = "")

$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $PSScriptRoot 'itemlimit_status.txt' }
function Report([string]$text) {
    try { [IO.File]::WriteAllText($Out, "ItemLimitResult=$text`r`n") } catch {}
}

if ($Limit -lt 99) { $Limit = 99 }
if ($Limit -gt 9999) { $Limit = 9999 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FfrsMem {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool VirtualProtectEx(IntPtr h, IntPtr addr, IntPtr size, uint prot, out uint old);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool FlushInstructionCache(IntPtr h, IntPtr addr, IntPtr size);
}
'@

function Same([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}
function Hex([string]$s) { [byte[]]($s -split ' ' | ForEach-Object { [Convert]::ToByte($_, 16) }) }
$imm = [BitConverter]::GetBytes([int32]$Limit)
$raise = $Limit -gt 99

# Each patch: RVA (VA - 0x140000000), original bytes, bytes to write for this limit.
# "imm" patches change a `mov reg, 99`; "check" patches skip a `have >= 99` test (only when raising).
$patches = @(
    @{ Name = 'SetInventoryItem clamp';      Rva = 0x512b7a8; Orig = 'b9 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'battle reward overflow A';    Rva = 0x4fb997b; Orig = 'b9 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'battle reward overflow B';    Rva = 0x4fb9a4a; Orig = 'b9 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'GetMaxItemNum';               Rva = 0x501ee03; Orig = 'b8 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'GetMaxItemNumById 1';         Rva = 0x501ee4f; Orig = 'ba 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'GetMaxItemNumById 2';         Rva = 0x501ee63; Orig = 'ba 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'GetMaxItemNumById 3';         Rva = 0x501ee77; Orig = 'ba 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'GetMaxItemNumById 4';         Rva = 0x501eeae; Orig = 'ba 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'GetMaxItemNumById 5';         Rva = 0x501eec2; Orig = 'ba 63 00 00 00'; Kind = 'imm' }
    @{ Name = 'add check (have+n<=99)';      Rva = 0x5096612; Orig = '83 f8 63 7e';       New = '83 f8 63 eb' }
    @{ Name = 'pickup check (have<99)';      Rva = 0x51570ee; Orig = '83 f8 63 7c';       New = '83 f8 63 eb' }
    @{ Name = 'shop can-buy A';              Rva = 0x5207014; Orig = '83 f8 63 0f 9c c0'; New = 'b0 01 90 90 90 90' }
    @{ Name = 'shop can-buy B';              Rva = 0x5209dc3; Orig = '83 f8 63 7c';       New = '83 f8 63 eb' }
    @{ Name = 'shop list check';             Rva = 0x52226de; Orig = '83 f8 63 0f 8c';    New = '83 f8 63 90 e9' }
)

$procs = @(Get-Process -Name 'FFRS-Win64-Shipping' -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) { Report "no game process"; exit 1 }

# Blueprint mode: the shop buy dialog (WBP_DialogCustomContet_ShopBuy) checks "held < 99" and
# uses 99 as the stack size for the buyable count. Each spec points at an EX_IntConst (0x1D +
# int32) inside a UFunction's Script bytecode (TArray at UFunction + 0x60, heap memory).
if ($BpFuncs) {
    $bpOut = Join-Path $PSScriptRoot 'itemlimit_bp_status.txt'
    $p = $procs[0]
    $h = [FfrsMem]::OpenProcess(0x0438, $false, $p.Id)
    $ok = 0; $bad = @(); $specs = @($BpFuncs.Split(',') | Where-Object { $_ })
    try {
        foreach ($spec in $specs) {
            $fn, $off = $spec.Split('@')
            $fnAddr = [Convert]::ToInt64($fn, 16); $off = [int]$off
            $hdr = New-Object byte[] 16; $n = [IntPtr]::Zero
            if (-not [FfrsMem]::ReadProcessMemory($h, [IntPtr]($fnAddr + 0x60), $hdr, [IntPtr]16, [ref]$n)) { $bad += "${spec}: read header"; continue }
            $code = [BitConverter]::ToInt64($hdr, 0); $len = [BitConverter]::ToInt32($hdr, 8)
            if ($code -le 0x10000 -or $off + 5 -gt $len) { $bad += "${spec}: no bytecode"; continue }
            $cur = New-Object byte[] 5
            if (-not [FfrsMem]::ReadProcessMemory($h, [IntPtr]($code + $off), $cur, [IntPtr]5, [ref]$n)) { $bad += "${spec}: read code"; continue }
            $val = [BitConverter]::ToInt32($cur, 1)
            # Only touch an int constant that holds the original 99 or an earlier limit of ours.
            if ($cur[0] -ne 0x1D -or $val -lt 99 -or $val -gt 9999) { $bad += "${spec}: unexpected bytes"; continue }
            if ($val -eq $Limit) { $ok++; continue }
            if ([FfrsMem]::WriteProcessMemory($h, [IntPtr]($code + $off + 1), $imm, [IntPtr]4, [ref]$n)) { $ok++ } else { $bad += "${spec}: write" }
        }
    } finally { [void][FfrsMem]::CloseHandle($h) }
    $s = "shop dialog limit $Limit, $ok/$($specs.Count) ok"
    if ($bad.Count) { $s += " | " + ($bad -join '; ') }
    try { [IO.File]::WriteAllText($bpOut, "ShopDialogResult=$s`r`n") } catch {}
    exit 0
}

$summary = @()
foreach ($p in $procs) {
    $base = $p.MainModule.BaseAddress
    $h = [FfrsMem]::OpenProcess(0x0438, $false, $p.Id)  # VM_OPERATION | VM_READ | VM_WRITE | QUERY_INFORMATION
    if ($h -eq [IntPtr]::Zero) { $summary += "pid $($p.Id): open failed"; continue }
    $ok = 0; $bad = @()
    try {
        foreach ($x in $patches) {
            $orig = Hex $x.Orig
            if ($x.Kind -eq 'imm') {
                $want = [byte[]](@($orig[0]) + $(if ($raise) { $imm } else { $orig[1..4] }))
            } else {
                $want = if ($raise) { Hex $x.New } else { $orig }
            }
            $addr = [IntPtr]($base.ToInt64() + $x.Rva)
            $len = [IntPtr]$orig.Length
            $cur = New-Object byte[] $orig.Length
            $n = [IntPtr]::Zero
            if (-not [FfrsMem]::ReadProcessMemory($h, $addr, $cur, $len, [ref]$n)) { $bad += "$($x.Name): read"; continue }
            # Only touch bytes that are either the original code or one of our own patches.
            $isOrig = Same $cur $orig
            $isOurs = if ($x.Kind -eq 'imm') { $cur[0] -eq $orig[0] } else { Same $cur (Hex $x.New) }
            if (-not ($isOrig -or $isOurs)) { $bad += "$($x.Name): unexpected bytes $(($cur | ForEach-Object { $_.ToString('x2') }) -join ' ')"; continue }
            if (Same $cur $want) { $ok++; continue }
            $old = [uint32]0
            if (-not [FfrsMem]::VirtualProtectEx($h, $addr, $len, 0x40, [ref]$old)) { $bad += "$($x.Name): protect"; continue }
            $w = [FfrsMem]::WriteProcessMemory($h, $addr, $want, $len, [ref]$n)
            $tmp = [uint32]0
            [void][FfrsMem]::VirtualProtectEx($h, $addr, $len, $old, [ref]$tmp)
            [void][FfrsMem]::FlushInstructionCache($h, $addr, $len)
            if ($w) { $ok++ } else { $bad += "$($x.Name): write" }
        }
    } finally { [void][FfrsMem]::CloseHandle($h) }
    $s = "limit $Limit, $ok/$($patches.Count) ok"
    if ($bad.Count) { $s += " | " + ($bad -join '; ') }
    $summary += $s
}
Report ($summary -join ' || ')
