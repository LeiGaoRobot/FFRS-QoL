# FFRS_QoL 设置窗口：编辑 config.ini，游戏内 mod 会在约 1 秒内自动应用。
# -FromGame: opened automatically by the mod at game start; no focus steal, closes when the game exits.
# -Lang zh|en: force a UI language. Otherwise UILanguage in config.ini (zh / en / auto);
# auto = Chinese on Chinese Windows, English elsewhere.
# -Reopened: started by the language switch; brings itself to the front.
param([switch]$FromGame, [string]$Lang = '', [switch]$Reopened)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($Lang -ne 'zh' -and $Lang -ne 'en') {
    $cfgLang = ''
    try {
        $hit = Select-String -LiteralPath (Join-Path $PSScriptRoot 'config.ini') -Pattern '^\s*UILanguage\s*=\s*(\w+)' | Select-Object -First 1
        if ($hit) { $cfgLang = $hit.Matches[0].Groups[1].Value.ToLower() }
    } catch {}
    $Lang = if ($cfgLang -eq 'zh' -or $cfgLang -eq 'en') { $cfgLang }
            elseif ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*') { 'zh' } else { 'en' }
}
$UseZh = ($Lang -eq 'zh')
function T([string]$zh, [string]$en) { if ($UseZh) { return $zh } else { return $en } }
$WinTitle = T 'FFRS QoL 设置' 'FFRS QoL Settings'

# Single instance: a second launch just brings the existing window forward (or does nothing from the game).
$createdNew = $false
$script:instanceMutex = New-Object System.Threading.Mutex($true, 'Local\FFRS_QoL_Settings', [ref]$createdNew)
if (-not $createdNew) {
    if (-not $FromGame) {
        try {
            Add-Type -AssemblyName Microsoft.VisualBasic
            [void][Microsoft.VisualBasic.Interaction]::AppActivate($WinTitle)
        } catch {}
    }
    exit
}
try {
    Add-Type -Name Dpi -Namespace Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][Win32.Dpi]::SetProcessDPIAware()
} catch {}
[System.Windows.Forms.Application]::EnableVisualStyles()

$ModDir     = $PSScriptRoot
$ConfigPath = Join-Path $ModDir 'config.ini'
$StatusPath = Join-Path $ModDir 'status.txt'
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

$Defaults = [ordered]@{
    EncountersEnabled  = '1'
    EncounterRate      = '1.00'
    UILanguage         = 'auto'
    ExpMultiplier      = '2.00'
    MoneyMultiplier    = '2.00'
    MRPointMultiplier  = '1.00'
    DropMultiplier     = '1.00'
    RareAlwaysDrop     = '0'
    APMultiplier       = '1.00'
    BattleSpeedMultiplier = '1.00'
    AlwaysEscape       = '0'
    ItemLimit          = '99'
    APCapacityBonus    = '0'
    AutoRepeat         = '0'
    SmartSupport       = '1'
    AutoOpenSettings   = '1'
    ToggleEncounterKey = 'F6'
    CycleMultiplierKey = 'F7'
    AutoRepeatKey      = 'F8'
    RepeatCommandKey   = 'F9'
    ToggleEncounterPad = ''
    CycleMultiplierPad = ''
    RepeatCommandPad   = 'R3'
    AutoRepeatPad      = 'L3'
    CyclePresets       = '1,2,3,5'
}
# Gamepad binding suggestions (editable). $PadNone = not bound.
$PadNone = T '无' 'None'
$PadChoices = @($PadNone, 'R3', 'L3', 'LT+A', 'LT+B', 'LT+X', 'LT+Y', 'RT+A', 'RT+B', 'RT+X', 'RT+Y',
                'LB+RB', 'LT+RT', 'LB+UP', 'LB+DOWN', 'RB+UP', 'RB+DOWN', 'L3+R3')
$PadTokens = @('A','B','X','Y','LB','RB','LT','RT','L3','R3','UP','DOWN','LEFT','RIGHT','BACK','VIEW','SELECT','START','MENU')
function Normalize-Pad([string]$s) {
    $s = ($s -replace '\s', '').ToUpper()
    if ($s -eq '' -or $s -eq '无' -or $s -eq 'NONE') { return '' }
    foreach ($t in ($s -split '\+')) { if ($PadTokens -notcontains $t) { return $null } }
    return $s
}
# Bindable keyboard keys: UE4SS Key names -> Windows virtual-key codes (Esc is kept for cancel).
$KeyVk = [ordered]@{
    'F1'=112; 'F2'=113; 'F3'=114; 'F4'=115; 'F5'=116; 'F6'=117; 'F7'=118; 'F8'=119
    'F9'=120; 'F10'=121; 'F11'=122; 'F12'=123; 'F13'=124; 'F14'=125; 'F15'=126; 'F16'=127
    'F17'=128; 'F18'=129; 'F19'=130; 'F20'=131; 'F21'=132; 'F22'=133; 'F23'=134; 'F24'=135
    'XBUTTON_ONE'=5; 'XBUTTON_TWO'=6; 'INS'=45; 'DEL'=46; 'HOME'=36; 'END'=35; 'PAGE_UP'=33; 'PAGE_DOWN'=34
    'NUM_ZERO'=96; 'NUM_ONE'=97; 'NUM_TWO'=98; 'NUM_THREE'=99; 'NUM_FOUR'=100; 'NUM_FIVE'=101; 'NUM_SIX'=102; 'NUM_SEVEN'=103
    'NUM_EIGHT'=104; 'NUM_NINE'=105; 'MULTIPLY'=106; 'ADD'=107; 'SUBTRACT'=109; 'DECIMAL'=110; 'DIVIDE'=111; 'A'=65
    'B'=66; 'C'=67; 'D'=68; 'E'=69; 'F'=70; 'G'=71; 'H'=72; 'I'=73
    'J'=74; 'K'=75; 'L'=76; 'M'=77; 'N'=78; 'O'=79; 'P'=80; 'Q'=81
    'R'=82; 'S'=83; 'T'=84; 'U'=85; 'V'=86; 'W'=87; 'X'=88; 'Y'=89
    'Z'=90; 'ZERO'=48; 'ONE'=49; 'TWO'=50; 'THREE'=51; 'FOUR'=52; 'FIVE'=53; 'SIX'=54
    'SEVEN'=55; 'EIGHT'=56; 'NINE'=57; 'SPACE'=32; 'TAB'=9; 'RETURN'=13; 'BACKSPACE'=8; 'PAUSE'=19
    'CAPS_LOCK'=20; 'LEFT_ARROW'=37; 'UP_ARROW'=38; 'RIGHT_ARROW'=39; 'DOWN_ARROW'=40; 'PRINT_SCREEN'=44; 'NUM_LOCK'=144; 'SCROLL_LOCK'=145
    'OEM_ONE'=186; 'OEM_PLUS'=187; 'OEM_COMMA'=188; 'OEM_MINUS'=189; 'OEM_PERIOD'=190; 'OEM_TWO'=191; 'OEM_THREE'=192; 'OEM_FOUR'=219
    'OEM_FIVE'=220; 'OEM_SIX'=221; 'OEM_SEVEN'=222
}
$KeyChoices = @($KeyVk.Keys)
$VkName = @{}; foreach ($k in $KeyVk.Keys) { $VkName[[int]$KeyVk[$k]] = $k }

function Read-KeyValues([string]$path) {
    $map = @{}
    if (Test-Path -LiteralPath $path) {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$') { $map[$Matches[1]] = $Matches[2] }
        }
    }
    return $map
}

function Read-Config {
    $cfg = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $cfg[$k] = $Defaults[$k] }
    $file = Read-KeyValues $ConfigPath
    foreach ($k in $file.Keys) { if ($cfg.Contains($k)) { $cfg[$k] = $file[$k] } }
    return $cfg
}

$script:lastOwnWrite = [datetime]::MinValue
function Write-Config($cfg) {
    $lines = @('; FFRS_QoL settings - changes apply in game within ~1 second.',
               '; Key changes need a game restart.')
    foreach ($k in $cfg.Keys) { $lines += "$k=$($cfg[$k])" }
    $tmp = "$ConfigPath.tmp"
    [System.IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"), $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    $script:lastOwnWrite = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
}

function To-Decimal([string]$s, [decimal]$fallback) {
    $d = [decimal]0
    if ([decimal]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return [Math]::Min([decimal]10, [Math]::Max([decimal]0, [Math]::Round($d, 1)))
    }
    return $fallback
}

# ---------------------------------------------------------------- UI
$fontName = T 'Microsoft YaHei UI' 'Segoe UI'
$font     = New-Object System.Drawing.Font($fontName, 9)
$fontBold = New-Object System.Drawing.Font($fontName, 9, [System.Drawing.FontStyle]::Bold)
$fontBig  = New-Object System.Drawing.Font($fontName, 12, [System.Drawing.FontStyle]::Bold)
$grey     = [System.Drawing.Color]::FromArgb(110, 110, 110)

$form = New-Object System.Windows.Forms.Form
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Text = $WinTitle
$form.Font = $font
$form.ClientSize = New-Object System.Drawing.Size(1000, 744)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.TopMost = $false

function New-Label($text, $x, $y, $w = 120, $h = 22) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.TextAlign = 'MiddleLeft'
    return $l
}

# Header band: title, connection status, language
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0); $header.Size = New-Object System.Drawing.Size(1000, 86)
$header.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($header)
$headerLine = New-Object System.Windows.Forms.Label
$headerLine.Location = New-Object System.Drawing.Point(0, 85); $headerLine.Size = New-Object System.Drawing.Size(1000, 1)
$headerLine.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$header.Controls.Add($headerLine)
$title = New-Label (T 'FFRS 便利功能设置' 'FFRS Quality-of-Life Settings') 16 10 400 30
$title.Font = $fontBig
$langLabel = New-Label (T '语言' 'Language') 770 12 90 26
$langLabel.TextAlign = 'MiddleRight'
$header.Controls.Add($langLabel)
$cbLang = New-Object System.Windows.Forms.ComboBox
$cbLang.DropDownStyle = 'DropDownList'
[void]$cbLang.Items.AddRange(@((T '自动' 'Auto'), '中文', 'English'))
$cbLang.Location = New-Object System.Drawing.Point(864, 14); $cbLang.Size = New-Object System.Drawing.Size(120, 24)
$header.Controls.Add($cbLang)
# Same top and height as the dropdown, so the label text centers on the dropdown text.
$langLabel.Top = $cbLang.Top; $langLabel.Height = $cbLang.Height
if ($UseZh) { $langLabel.Top += 3 }  # YaHei draws label text higher than the dropdown's
$LangCodes = @('auto', 'zh', 'en')
$header.Controls.Add($title)

$statusDot = New-Label '●' 16 42 20 22
$statusDot.ForeColor = $grey
$header.Controls.Add($statusDot)
$statusText = New-Label (T '正在检测游戏…' 'Checking for the game…') 36 42 900 22
$statusText.Font = $fontBold
$header.Controls.Add($statusText)
$statusDetail = New-Label '' 36 62 900 22
$statusDetail.ForeColor = $grey
$header.Controls.Add($statusDetail)


# Encounters
$grpEnc = New-Object System.Windows.Forms.GroupBox
$grpEnc.Text = T '遇敌' 'Encounters'; $grpEnc.Location = New-Object System.Drawing.Point(12, 98)
$grpEnc.Size = New-Object System.Drawing.Size(520, 118)
$chkEnc = New-Object System.Windows.Forms.CheckBox
$chkEnc.Text = T '启用随机遇敌' 'Random encounters'
$chkEnc.Location = New-Object System.Drawing.Point(14, 24); $chkEnc.Size = New-Object System.Drawing.Size(440, 26)
$grpEnc.Controls.Add($chkEnc)
$grpEnc.Controls.Add((New-Label (T '频率' 'Rate') 32 52 80 26))
$nuEncRate = New-Object System.Windows.Forms.NumericUpDown
$nuEncRate.Minimum = 0.1; $nuEncRate.Maximum = 5; $nuEncRate.DecimalPlaces = 2; $nuEncRate.Increment = 0.25
$nuEncRate.Location = New-Object System.Drawing.Point(112, 54); $nuEncRate.Size = New-Object System.Drawing.Size(74, 26)
$grpEnc.Controls.Add($nuEncRate)
$encRateHint = New-Label (T '倍（2 = 遇敌翻倍，0.5 = 减半）' 'x (2 = twice as often, 0.5 = half)') 192 52 318 26
$encRateHint.ForeColor = $grey
$grpEnc.Controls.Add($encRateHint)
$encHint = New-Label (T '取消勾选后走路不会遇敌；剧情战、固定战斗不受影响' 'Off: no random battles; story/fixed battles still happen') 32 84 480 24
$encHint.ForeColor = $grey
$grpEnc.Controls.Add($encHint)
$form.Controls.Add($grpEnc)

# Battle
$grpBattle = New-Object System.Windows.Forms.GroupBox
$grpBattle.Text = T '战斗' 'Battle'; $grpBattle.Location = New-Object System.Drawing.Point(12, 224)
$grpBattle.Size = New-Object System.Drawing.Size(520, 118)
$form.Controls.Add($grpBattle)
$grpBattle.Controls.Add((New-Label (T '战斗速度' 'Speed') 14 28 96 26))
$nuSpeed = New-Object System.Windows.Forms.NumericUpDown
$nuSpeed.Minimum = 0.5; $nuSpeed.Maximum = 4; $nuSpeed.DecimalPlaces = 1; $nuSpeed.Increment = 0.5
$nuSpeed.Location = New-Object System.Drawing.Point(112, 30); $nuSpeed.Size = New-Object System.Drawing.Size(74, 26)
$grpBattle.Controls.Add($nuSpeed)
$speedHint = New-Label (T '倍（叠加游戏自带的 1/1.5/2 倍速）' 'x (stacks with in-game 1/1.5/2x)') 192 28 318 26
$speedHint.ForeColor = $grey
$grpBattle.Controls.Add($speedHint)
$chkEscape = New-Object System.Windows.Forms.CheckBox
$chkEscape.Text = T '逃跑必定成功' 'Escape always succeeds'
$chkEscape.Location = New-Object System.Drawing.Point(14, 62); $chkEscape.Size = New-Object System.Drawing.Size(440, 26)
$grpBattle.Controls.Add($chkEscape)
$escHint = New-Label (T '只对允许逃跑的战斗生效；Boss 战、剧情战不受影响' 'Only where fleeing is allowed; not bosses or story battles') 32 88 480 22
$escHint.ForeColor = $grey
$grpBattle.Controls.Add($escHint)

# Repeat last command (right column, below the multipliers)
$grpRep = New-Object System.Windows.Forms.GroupBox
$grpRep.Text = T '重复上次指令' 'Repeat last command'; $grpRep.Location = New-Object System.Drawing.Point(12, 350)
$grpRep.Size = New-Object System.Drawing.Size(520, 146)
$form.Controls.Add($grpRep)
$chkRepeat = New-Object System.Windows.Forms.CheckBox
$chkRepeat.Text = T '自动重复（简易自动战斗）' 'Auto repeat (simple auto battle)'
$chkRepeat.Location = New-Object System.Drawing.Point(14, 24); $chkRepeat.Size = New-Object System.Drawing.Size(440, 26)
$grpRep.Controls.Add($chkRepeat)
$repHint = New-Label (T '沿用每个角色上次的指令，没记录的角色需手动选' "Reuses each character's last command") 32 50 430 22
$repHint.ForeColor = $grey
$grpRep.Controls.Add($repHint)
$chkSmart = New-Object System.Windows.Forms.CheckBox
$chkSmart.Text = T '辅助技能智能选目标' 'Smart targeting for support skills'
$chkSmart.Location = New-Object System.Drawing.Point(14, 82); $chkSmart.Size = New-Object System.Drawing.Size(440, 26)
$grpRep.Controls.Add($chkSmart)
$smartHint = New-Label (T '回复给 HP 最低的队友，增益给还没有的队友' 'Heals the lowest-HP ally; buffs allies that lack it') 32 108 430 22
$smartHint.ForeColor = $grey
$grpRep.Controls.Add($smartHint)

# Items (right column, bottom)
$grpItem = New-Object System.Windows.Forms.GroupBox
$grpItem.Text = T '物品与能力' 'Items and abilities'; $grpItem.Location = New-Object System.Drawing.Point(544, 364)
$grpItem.Size = New-Object System.Drawing.Size(444, 132)
$form.Controls.Add($grpItem)
$grpItem.Controls.Add((New-Label (T '持有上限' 'Carry limit') 14 26 96 26))
$nuItem = New-Object System.Windows.Forms.NumericUpDown
$nuItem.Minimum = 99; $nuItem.Maximum = 9999; $nuItem.Increment = 100
$nuItem.Location = New-Object System.Drawing.Point(112, 28); $nuItem.Size = New-Object System.Drawing.Size(84, 26)
$grpItem.Controls.Add($nuItem)
$itemHint = New-Label (T '每种物品最多持有数量，原版 99；设回 99 即恢复' 'Max per item; the game uses 99. Set 99 to restore') 14 60 420 26
$itemHint.ForeColor = $grey
$grpItem.Controls.Add($itemHint)
$itemState = New-Label '' 202 26 232 26
$itemState.ForeColor = $grey
$grpItem.Controls.Add($itemState)
# ItemLimit.ps1 is an optional download (antivirus heuristics flag its memory patching).
$HasItemLimit = Test-Path -LiteralPath (Join-Path $ModDir 'ItemLimit.ps1')
if (-not $HasItemLimit) {
    $nuItem.Enabled = $false
    $itemHint.Text = T '需要另外下载可选文件"物品上限"（ItemLimit.ps1）' 'Needs the optional "Item limit" file (ItemLimit.ps1)'
}
$grpItem.Controls.Add((New-Label (T '能力 AP +' 'AP limit +') 14 94 96 26))
$nuAP = New-Object System.Windows.Forms.NumericUpDown
$nuAP.Minimum = 0; $nuAP.Maximum = 9999; $nuAP.Increment = 50
$nuAP.Location = New-Object System.Drawing.Point(112, 96); $nuAP.Size = New-Object System.Drawing.Size(84, 26)
$grpItem.Controls.Add($nuAP)
$apHint = New-Label (T '所有角色都加，读档后生效' 'All characters; reload a save') 202 94 232 26
$apHint.ForeColor = $grey
$grpItem.Controls.Add($apHint)

# Multipliers (right column)
$grpMul = New-Object System.Windows.Forms.GroupBox
$grpMul.Text = T '战斗奖励倍率（0 – 10 倍）' 'Battle reward multipliers (0 – 10x)'; $grpMul.Location = New-Object System.Drawing.Point(544, 98)
$grpMul.Size = New-Object System.Drawing.Size(444, 258)
$form.Controls.Add($grpMul)

$sliders = @{}
$spinners = @{}
$rows = @(
    @{ Key = 'ExpMultiplier';     Text = (T '经验' 'EXP') },
    @{ Key = 'MoneyMultiplier';   Text = (T '金钱 (Gil)' 'Gil') },
    @{ Key = 'MRPointMultiplier'; Text = (T 'MR 点' 'MR points') },
    @{ Key = 'APMultiplier';      Text = 'AP' },
    @{ Key = 'DropMultiplier';    Text = (T '物品掉落' 'Item drops') }
)
$y = 24
foreach ($r in $rows) {
    $grpMul.Controls.Add((New-Label $r.Text 14 ($y + 4) 96 26))
    $tb = New-Object System.Windows.Forms.TrackBar
    $tb.AutoSize = $false; $tb.BackColor = [System.Drawing.SystemColors]::Control
    $tb.Minimum = 0; $tb.Maximum = 100; $tb.TickFrequency = 10; $tb.SmallChange = 1; $tb.LargeChange = 10
    $tb.Location = New-Object System.Drawing.Point(112, $y); $tb.Size = New-Object System.Drawing.Size(240, 34)
    $nu = New-Object System.Windows.Forms.NumericUpDown
    $nu.Minimum = 0; $nu.Maximum = 10; $nu.DecimalPlaces = 1; $nu.Increment = 0.1
    $nu.Location = New-Object System.Drawing.Point(360, ($y + 4)); $nu.Size = New-Object System.Drawing.Size(70, 26)
    $grpMul.Controls.Add($tb); $grpMul.Controls.Add($nu)
    $sliders[$r.Key] = $tb; $spinners[$r.Key] = $nu
    $y += 36
}

$dropHint = New-Label (T '掉落概率 × 倍率，最高 100%' 'Drop chance × multiplier, max 100%') 112 ($y - 4) 360 24
$dropHint.ForeColor = $grey
$grpMul.Controls.Add($dropHint)

$chkRare = New-Object System.Windows.Forms.CheckBox
$chkRare.Text = T '稀有物品必掉（100%）' 'Rare items always drop (100%)'
$chkRare.Location = New-Object System.Drawing.Point(112, ($y + 22)); $chkRare.Size = New-Object System.Drawing.Size(360, 26)
$grpMul.Controls.Add($chkRare)

# Hotkeys: one row per action, keyboard key + gamepad binding
$grpKey = New-Object System.Windows.Forms.GroupBox
$grpKey.Text = T '快捷键' 'Hotkeys'; $grpKey.Location = New-Object System.Drawing.Point(12, 504)
$grpKey.Size = New-Object System.Drawing.Size(976, 182)
$form.Controls.Add($grpKey)

$hdr1 = New-Label (T '键盘' 'Keyboard') 150 20 135 24; $hdr1.ForeColor = $grey; $grpKey.Controls.Add($hdr1)
$hdr2 = New-Label (T '手柄' 'Gamepad') 318 20 220 24; $hdr2.ForeColor = $grey; $grpKey.Controls.Add($hdr2)

# "Record" button next to a binding box: click it, then press the key / pad button(s).
$script:captureButtons = @()
function New-CaptureButton($kind, $combo, $x, $y) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = T '录制' 'Set'
    $b.Location = New-Object System.Drawing.Point($x, ($y - 1)); $b.Size = New-Object System.Drawing.Size(56, 26)
    $b.UseVisualStyleBackColor = $true
    $b.Tag = @{ Kind = $kind; Combo = $combo }
    $b.Add_Click({ Start-Capture $this })
    # Let Tab, arrows and Enter reach KeyDown while recording instead of moving focus.
    $b.Add_PreviewKeyDown({ param($s, $e) if ($script:capture) { $e.IsInputKey = $true } })
    $b.Add_MouseDown({ param($s, $e) Capture-Mouse $e.Button })
    $grpKey.Controls.Add($b)
    $script:captureButtons += $b
    return $b
}

function New-KeyRow($text, $y) {
    $grpKey.Controls.Add((New-Label $text 14 $y 130 26))
    $cbK = New-Object System.Windows.Forms.ComboBox
    $cbK.DropDownStyle = 'DropDownList'; [void]$cbK.Items.AddRange($KeyChoices)
    $cbK.Location = New-Object System.Drawing.Point(150, $y); $cbK.Size = New-Object System.Drawing.Size(104, 24)
    $grpKey.Controls.Add($cbK)
    $cbP = New-Object System.Windows.Forms.ComboBox
    $cbP.DropDownStyle = 'DropDown'; [void]$cbP.Items.AddRange($PadChoices)
    $cbP.Location = New-Object System.Drawing.Point(318, $y); $cbP.Size = New-Object System.Drawing.Size(104, 24)
    $grpKey.Controls.Add($cbP)
    [void](New-CaptureButton 'key' $cbK 256 $y)
    [void](New-CaptureButton 'pad' $cbP 424 $y)
    return @($cbK, $cbP)
}
$r = New-KeyRow (T '开关遇敌' 'Encounters') 46;      $cbEnc = $r[0];    $pdEnc = $r[1]
$r = New-KeyRow (T '循环倍率' 'Cycle rates') 78;      $cbMul = $r[0];    $pdMul = $r[1]
$r = New-KeyRow (T '重复上次指令' 'Repeat last') 110; $cbRepeat = $r[0]; $pdRepeat = $r[1]
$r = New-KeyRow (T '开关自动重复' 'Auto repeat') 142; $cbAutoRep = $r[0]; $pdAutoRep = $r[1]

$grpKey.Controls.Add((New-Label (T '循环档位' 'Cycle steps') 512 44 100 26))
$txtPresets = New-Object System.Windows.Forms.TextBox
$txtPresets.Location = New-Object System.Drawing.Point(614, 45); $txtPresets.Size = New-Object System.Drawing.Size(110, 26)
$grpKey.Controls.Add($txtPresets)
$hint = New-Label (T '经验、金钱同时切换' 'EXP and Gil together') 732 44 210 26
$hint.ForeColor = $grey
$grpKey.Controls.Add($hint)
$PadHintText = T '点"录制"后按下按键即可绑定；键盘改键需重启游戏' 'Click Set, then press the key. Keys need a game restart.'
$padHint = New-Label $PadHintText 512 90 450 24
$padHint.ForeColor = $grey
$grpKey.Controls.Add($padHint)
$padHint2 = New-Label (T '背键：先在手柄 App 里映射成键盘键（如 F8、F9）' 'Back paddles: map them to F8/F9 in your pad tool') 512 118 450 24
$padHint2.ForeColor = $grey
$grpKey.Controls.Add($padHint2)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = T '启动游戏时自动打开此窗口' 'Open with the game'
$chkAuto.Location = New-Object System.Drawing.Point(16, 704); $chkAuto.Size = New-Object System.Drawing.Size(330, 26)
$form.Controls.Add($chkAuto)

# Buttons
$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = T '恢复默认' 'Defaults'; $btnReset.Location = New-Object System.Drawing.Point(700, 700)
$btnReset.Size = New-Object System.Drawing.Size(104, 32)
$form.Controls.Add($btnReset)
$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = T '打开 mod 文件夹' 'Open mod folder'; $btnFolder.Location = New-Object System.Drawing.Point(812, 700)
$btnFolder.Size = New-Object System.Drawing.Size(176, 32)
$form.Controls.Add($btnFolder)
$saveLabel = New-Label '' 350 704 300 26
$saveLabel.TextAlign = 'MiddleLeft'; $saveLabel.ForeColor = $grey
$form.Controls.Add($saveLabel)

# ---------------------------------------------------------------- Logic
$script:loading = $false
$script:dirty = $false

function Show-Config($cfg) {
    $script:loading = $true
    $li = [array]::IndexOf($LangCodes, ([string]$cfg.UILanguage).ToLower()); if ($li -lt 0) { $li = 0 }
    $cbLang.SelectedIndex = $li
    $chkEnc.Checked = ($cfg.EncountersEnabled -eq '1' -or $cfg.EncountersEnabled -eq 'true')
    $er = [decimal]1; [void][decimal]::TryParse([string]$cfg.EncounterRate, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$er)
    $nuEncRate.Value = [Math]::Min([decimal]5, [Math]::Max([decimal]0.1, [Math]::Round($er, 2)))
    foreach ($r in $rows) {
        $v = To-Decimal $cfg[$r.Key] ([decimal]$Defaults[$r.Key])
        $spinners[$r.Key].Value = $v
        $sliders[$r.Key].Value = [int]($v * 10)
    }
    $chkRare.Checked = ($cfg.RareAlwaysDrop -eq '1' -or $cfg.RareAlwaysDrop -eq 'true')
    $chkAuto.Checked = ($cfg.AutoOpenSettings -eq '1' -or $cfg.AutoOpenSettings -eq 'true')
    $chkEscape.Checked = ($cfg.AlwaysEscape -eq '1' -or $cfg.AlwaysEscape -eq 'true')
    $chkRepeat.Checked = ($cfg.AutoRepeat -eq '1' -or $cfg.AutoRepeat -eq 'true')
    $chkSmart.Checked = ($cfg.SmartSupport -eq '1' -or $cfg.SmartSupport -eq 'true')
    $il = 99; [void][int]::TryParse([string]$cfg.ItemLimit, [ref]$il)
    $nuItem.Value = [Math]::Min(9999, [Math]::Max(99, $il))
    $ap = 0; [void][int]::TryParse([string]$cfg.APCapacityBonus, [ref]$ap)
    $nuAP.Value = [Math]::Min(9999, [Math]::Max(0, $ap))
    $k3 = $cfg.RepeatCommandKey; if ($KeyChoices -notcontains $k3) { $k3 = 'F9' }
    $k4 = $cfg.AutoRepeatKey; if ($KeyChoices -notcontains $k4) { $k4 = 'F8' }
    $cbRepeat.SelectedItem = $k3; $cbAutoRep.SelectedItem = $k4
    foreach ($pair in @(@($pdEnc, 'ToggleEncounterPad'), @($pdMul, 'CycleMultiplierPad'),
                        @($pdRepeat, 'RepeatCommandPad'), @($pdAutoRep, 'AutoRepeatPad'))) {
        $v = [string]$cfg[$pair[1]]
        $pair[0].Text = if ($v -eq '') { $PadNone } else { $v }
        $pair[0].ForeColor = [System.Drawing.SystemColors]::WindowText
    }
    $sp = To-Decimal $cfg.BattleSpeedMultiplier ([decimal]1)
    $nuSpeed.Value = [Math]::Min([decimal]4, [Math]::Max([decimal]0.5, $sp))
    $k1 = $cfg.ToggleEncounterKey; if ($KeyChoices -notcontains $k1) { $k1 = 'F6' }
    $k2 = $cfg.CycleMultiplierKey; if ($KeyChoices -notcontains $k2) { $k2 = 'F7' }
    $cbEnc.SelectedItem = $k1; $cbMul.SelectedItem = $k2
    $txtPresets.Text = $cfg.CyclePresets
    $script:loading = $false
}

function Collect-Config {
    $cfg = [ordered]@{}
    $cfg.EncountersEnabled  = if ($chkEnc.Checked) { '1' } else { '0' }
    $cfg.EncounterRate      = $nuEncRate.Value.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
    $cfg.UILanguage         = $LangCodes[[Math]::Max(0, $cbLang.SelectedIndex)]
    foreach ($r in $rows) { $cfg[$r.Key] = $spinners[$r.Key].Value.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture) }
    $cfg.RareAlwaysDrop     = if ($chkRare.Checked) { '1' } else { '0' }
    $cfg.AutoOpenSettings   = if ($chkAuto.Checked) { '1' } else { '0' }
    $cfg.AlwaysEscape       = if ($chkEscape.Checked) { '1' } else { '0' }
    $cfg.AutoRepeat         = if ($chkRepeat.Checked) { '1' } else { '0' }
    $cfg.SmartSupport       = if ($chkSmart.Checked) { '1' } else { '0' }
    $cfg.ItemLimit          = ([int]$nuItem.Value).ToString()
    $cfg.APCapacityBonus    = ([int]$nuAP.Value).ToString()
    $cfg.RepeatCommandKey   = [string]$cbRepeat.SelectedItem
    foreach ($pair in @(@($pdEnc, 'ToggleEncounterPad'), @($pdMul, 'CycleMultiplierPad'),
                        @($pdRepeat, 'RepeatCommandPad'), @($pdAutoRep, 'AutoRepeatPad'))) {
        $n = Normalize-Pad $pair[0].Text
        if ($null -eq $n) {
            # Invalid text: keep the previous saved value, mark the box red.
            $pair[0].ForeColor = [System.Drawing.Color]::Firebrick
            $old = (Read-Config)[$pair[1]]
            $cfg[$pair[1]] = if ($null -ne $old) { $old } else { $Defaults[$pair[1]] }
        } else {
            $pair[0].ForeColor = [System.Drawing.SystemColors]::WindowText
            $cfg[$pair[1]] = $n
        }
    }
    $cfg.AutoRepeatKey      = [string]$cbAutoRep.SelectedItem
    $cfg.BattleSpeedMultiplier = $nuSpeed.Value.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
    $cfg.ToggleEncounterKey = [string]$cbEnc.SelectedItem
    $cfg.CycleMultiplierKey = [string]$cbMul.SelectedItem
    $presets = ($txtPresets.Text -split '[,，\s]+' | Where-Object { $_ -match '^\d+(\.\d+)?$' }) -join ','
    $cfg.CyclePresets = if ($presets) { $presets } else { $Defaults.CyclePresets }
    return $cfg
}

$saveTimer = New-Object System.Windows.Forms.Timer
$saveTimer.Interval = 350
$saveTimer.Add_Tick({
    $saveTimer.Stop()
    try {
        Write-Config (Collect-Config)
        $script:dirty = $false
        $saveLabel.Text = (T '已保存 ' 'Saved ') + (Get-Date -Format 'HH:mm:ss')
    } catch {
        $saveLabel.Text = T '保存失败，稍后重试' 'Save failed, retrying'
        $saveTimer.Start()
    }
})
function Request-Save {
    if ($script:loading) { return }
    $script:dirty = $true
    $saveLabel.Text = T '保存中…' 'Saving…'
    $saveTimer.Stop(); $saveTimer.Start()
}

$chkEnc.Add_CheckedChanged({ Request-Save })
$nuEncRate.Add_ValueChanged({ Request-Save })
$chkRare.Add_CheckedChanged({ Request-Save })
$chkAuto.Add_CheckedChanged({ Request-Save })
$chkEscape.Add_CheckedChanged({ Request-Save })
$chkRepeat.Add_CheckedChanged({ Request-Save })
$chkSmart.Add_CheckedChanged({ Request-Save })
$cbRepeat.Add_SelectedIndexChanged({ Request-Save })
$cbAutoRep.Add_SelectedIndexChanged({ Request-Save })
foreach ($pd in @($pdEnc, $pdMul, $pdRepeat, $pdAutoRep)) {
    $pd.Add_TextChanged({ Request-Save })
}
$nuSpeed.Add_ValueChanged({ Request-Save })
$nuItem.Add_ValueChanged({ Request-Save })
$nuAP.Add_ValueChanged({ Request-Save })
foreach ($r in $rows) {
    $tb = $sliders[$r.Key]; $nu = $spinners[$r.Key]
    $tb.Add_ValueChanged({
        if ($script:loading) { return }
        $script:loading = $true; $this.Tag.Value = [decimal]$this.Value / 10; $script:loading = $false
        Request-Save
    })
    $nu.Add_ValueChanged({
        if ($script:loading) { return }
        $script:loading = $true; $this.Tag.Value = [int]($this.Value * 10); $script:loading = $false
        Request-Save
    })
    $tb.Tag = $nu; $nu.Tag = $tb
}
$cbEnc.Add_SelectedIndexChanged({ Request-Save })
$cbMul.Add_SelectedIndexChanged({ Request-Save })
$txtPresets.Add_TextChanged({ Request-Save })

$btnReset.Add_Click({
    $cfg = [ordered]@{}; foreach ($k in $Defaults.Keys) { $cfg[$k] = $Defaults[$k] }
    Show-Config $cfg; Request-Save
})
$btnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$ModDir`"" })


# ---------------------------------------------------------------- Press-to-bind
# Keyboard: the next key pressed while recording (Esc cancels). Gamepad: XInput is polled;
# every button held during the press is collected and the chord is set when all are released.
Add-Type -Name XInput -Namespace FfrsPad -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct State { public uint Packet; public ushort Buttons; public byte LT; public byte RT; public short LX; public short LY; public short RX; public short RY; }
[DllImport("xinput1_4.dll")] public static extern uint XInputGetState(uint index, out State state);
'@
# Order = order in the saved chord (modifiers first). LT/RT are analog, given pseudo bits.
$PadBits = [ordered]@{ LT = 0x10000; RT = 0x20000; LB = 0x0100; RB = 0x0200; A = 0x1000; B = 0x2000; X = 0x4000; Y = 0x8000;
                       L3 = 0x0040; R3 = 0x0080; UP = 0x0001; DOWN = 0x0002; LEFT = 0x0004; RIGHT = 0x0008; BACK = 0x0020; START = 0x0010 }
$script:capture = $null
$CaptureReq = Join-Path $ModDir 'capture_request.txt'
$CaptureRes = Join-Path $ModDir 'capture_result.txt'
$capBlue = [System.Drawing.Color]::FromArgb(30, 90, 200)
$capFill = [System.Drawing.Color]::FromArgb(255, 232, 150)

function Stop-Capture([string]$msg, [bool]$isError = $false) {
    $c = $script:capture
    if (-not $c) { return }
    $script:capture = $null
    $padTimer.Stop()
    if ($c.ReqId) { Remove-Item -LiteralPath $CaptureReq -ErrorAction SilentlyContinue }
    $c.Button.BackColor = [System.Drawing.SystemColors]::Control
    $c.Button.UseVisualStyleBackColor = $true
    $c.Button.Text = T '录制' 'Set'
    $padHint.ForeColor = if ($isError) { [System.Drawing.Color]::Firebrick } elseif ($msg) { $capBlue } else { $grey }
    $padHint.Text = if ($msg) { $msg } else { $PadHintText }
    # Move focus off the button so the key's release can't click it again.
    try { $c.Combo.Focus() | Out-Null } catch {}
    if ($msg) { $script:hintResetAt = (Get-Date).AddSeconds(5) }
}

function Start-Capture($button) {
    Stop-Capture
    $script:capture = @{ Kind = $button.Tag.Kind; Combo = $button.Tag.Combo; Button = $button
                         Start = Get-Date; Union = 0; Seen = $false; Connected = $false }
    $button.BackColor = $capFill
    $button.Text = T '按键…' 'Press…'
    $padHint.ForeColor = $capBlue
    if ($button.Tag.Kind -eq 'key') {
        $padHint.Text = T '请按下要绑定的键盘键或鼠标侧键（Esc 取消）' 'Press a keyboard key or mouse side button (Esc cancels)'
    } else {
        $padHint.Text = T '请按下手柄按键或组合键（如 LT+Y），全部松开后生效；8 秒内有效' 'Press a pad button or combo (e.g. LT+Y); set when released, 8 s'
        if (Get-Process -Name 'FFRS-Win64-Shipping' -ErrorAction SilentlyContinue) {
            $script:capture.ReqId = [string](Get-Date).Ticks
            Remove-Item -LiteralPath $CaptureRes -ErrorAction SilentlyContinue
            try { [System.IO.File]::WriteAllText($CaptureReq, "id=$($script:capture.ReqId)`n") } catch { $script:capture.ReqId = $null }
        }
        $padTimer.Start()
    }
}

function Set-CapturedKey([string]$name) {
    $c = $script:capture
    $c.Combo.SelectedItem = $name
    Stop-Capture ((T '已绑定 ' 'Bound ') + $name + (T '（键盘改键需重启游戏才生效）' ' (restart the game for key changes)'))
}

function Capture-Mouse($btn) {
    $c = $script:capture
    if (-not $c -or $c.Kind -ne 'key') { return }
    if ($btn -eq [System.Windows.Forms.MouseButtons]::XButton1) { Set-CapturedKey 'XBUTTON_ONE' }
    elseif ($btn -eq [System.Windows.Forms.MouseButtons]::XButton2) { Set-CapturedKey 'XBUTTON_TWO' }
}

$form.KeyPreview = $true
$form.Add_KeyDown({
    param($s, $e)
    $c = $script:capture
    if (-not $c) { return }
    $e.Handled = $true; $e.SuppressKeyPress = $true
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Stop-Capture (T '已取消录制' 'Recording cancelled'); return }
    if ($c.Kind -ne 'key') { return }
    $name = $VkName[[int]$e.KeyCode]
    if (-not $name) {
        $padHint.ForeColor = [System.Drawing.Color]::Firebrick
        $padHint.Text = T '这个键不能单独绑定（如 Shift、Ctrl、Alt），请换一个；Esc 取消' "That key can't be bound alone (Shift/Ctrl/Alt); try another, Esc cancels"
        return
    }
    Set-CapturedKey $name
})
$form.Add_MouseDown({ param($s, $e) Capture-Mouse $e.Button })
$grpKey.Add_MouseDown({ param($s, $e) Capture-Mouse $e.Button })

$padTimer = New-Object System.Windows.Forms.Timer
$padTimer.Interval = 30
$padTimer.Add_Tick({
    $c = $script:capture
    if (-not $c -or $c.Kind -ne 'pad') { $padTimer.Stop(); return }
    $cur = 0
    for ($i = 0; $i -lt 4; $i++) {
        $st = New-Object FfrsPad.XInput+State
        if ([FfrsPad.XInput]::XInputGetState($i, [ref]$st) -eq 0) {
            $c.Connected = $true
            $cur = $cur -bor [int]$st.Buttons
            if ($st.LT -gt 100) { $cur = $cur -bor 0x10000 }
            if ($st.RT -gt 100) { $cur = $cur -bor 0x20000 }
        }
    }
    if ($c.ReqId -and (Test-Path -LiteralPath $CaptureRes)) {
        $res = Read-KeyValues $CaptureRes
        if ($res.id -eq $c.ReqId) {
            Remove-Item -LiteralPath $CaptureRes -ErrorAction SilentlyContinue
            $c.ReqId = $null
            if ($res.chord) {
                $c.Combo.Text = $res.chord
                Stop-Capture ((T '已绑定手柄 ' 'Bound pad ') + $res.chord + (T '（立即生效）' ' (applies now)'))
            } else { Stop-Capture (T '没有按键，已取消录制' 'No button pressed; cancelled') }
            return
        }
    }
    if (-not $c.Connected -and $c.ReqId -and -not $c.Told -and ((Get-Date) - $c.Start).TotalMilliseconds -gt 300) {
        $c.Told = $true
        $padHint.Text = T '设置窗口读不到手柄，请切到游戏窗口里按（10 秒内）' "Can't read the pad here; switch to the game and press it (10 s)"
    }
    if ($cur -ne 0) { $c.Union = $c.Union -bor $cur; $c.Seen = $true; return }
    if ($c.Seen) {
        $tokens = @(); foreach ($k in $PadBits.Keys) { if ($c.Union -band $PadBits[$k]) { $tokens += $k } }
        if ($tokens.Count -eq 0) { $c.Seen = $false; $c.Union = 0; return }
        if ($tokens.Count -gt 3) { Stop-Capture (T '最多只能组合 3 个键，请重新录制' 'At most 3 buttons; record again') $true; return }
        $chord = $tokens -join '+'
        $c.Combo.Text = $chord
        Stop-Capture ((T '已绑定手柄 ' 'Bound pad ') + $chord + (T '（立即生效）' ' (applies now)'))
        return
    }
    $limit = if ($c.ReqId -and -not $c.Connected) { 12 } else { 8 }
    if (((Get-Date) - $c.Start).TotalSeconds -gt $limit) {
        if ($c.Connected) { Stop-Capture (T '没有按键，已取消录制' 'No button pressed; cancelled') }
        else { Stop-Capture (T '没有检测到手柄：请开着游戏再录制，或直接输入（如 LT+Y）' 'No gamepad found: record with the game running, or type it (e.g. LT+Y)') $true }
    }
})

# Poll: pick up hotkey changes written by the game, and show live status.
$script:lastSeenConfig = [datetime]::MinValue
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 1000
function Update-State {
    if (-not $script:capture -and $script:hintResetAt -and (Get-Date) -gt $script:hintResetAt) {
        $script:hintResetAt = $null; $padHint.ForeColor = $grey; $padHint.Text = $PadHintText
    }
    try {
        if (-not $script:dirty -and (Test-Path -LiteralPath $ConfigPath)) {
            $t = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
            if ($t -ne $script:lastSeenConfig) {
                $script:lastSeenConfig = $t
                if ($t -ne $script:lastOwnWrite) { Show-Config (Read-Config) }
            }
        }
    } catch {}

    $running = $null -ne (Get-Process -Name 'FFRS-Win64-Shipping' -ErrorAction SilentlyContinue)
    if ($FromGame) {
        # Opened by the game: close a few seconds after the game is gone.
        if ($running) { $script:goneTicks = 0 }
        else {
            $script:goneTicks = [int]$script:goneTicks + 1
            if ($script:goneTicks -ge 3) { $pollTimer.Stop(); $form.Close(); return }
        }
    }
    $fresh = $false; $st = @{}
    if (Test-Path -LiteralPath $StatusPath) {
        $age = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $StatusPath).LastWriteTimeUtc).TotalSeconds
        $fresh = $age -lt 6
        try { $st = Read-KeyValues $StatusPath } catch {}
    }
    if ($running -and $fresh) {
        $statusDot.ForeColor = [System.Drawing.Color]::FromArgb(40, 160, 70)
        $statusText.Text = T '已连接游戏，设置会实时生效' 'Connected to the game; changes apply live'
        $parts = @()
        if ($st.Error) { $parts += (T '错误：' 'Error: ') + $st.Error }
        else {
            $enc = if ($st.Encounters -eq '1') { T '遇敌开' 'Encounters on' } else { T '遇敌关' 'Encounters off' }
            $parts += $enc
            if ($st.AutoRepeat -eq '1') { $parts += (T '自动重复开' 'Auto repeat on') }
            $parts += (T '难度 ' 'Difficulty ') + $st.DifficultyRows
            $parts += (T '地图 ' 'Maps ') + $st.MapRows
            if ($st.UnitRows) { $parts += (T '敌人 ' 'Enemies ') + $st.UnitRows }
            $parts += if ([int]$st.Players -gt 0) { T '角色已找到' 'Player found' } else { T '未在地图中' 'Not on a map' }
        }
        $statusDetail.Text = $parts -join ' · '
        $ir = [string]$st.ItemLimitResult
        if ($ir -match '^limit (\d+), (\d+)/(\d+) ok$' -and $Matches[2] -eq $Matches[3]) {
            $itemState.Text = if ($Matches[1] -eq '99') { T '当前：原版 99' 'Now: original 99' } else { (T '当前上限：' 'Active limit: ') + $Matches[1] }
            $itemState.ForeColor = [System.Drawing.Color]::FromArgb(40, 160, 70)
        } elseif ($ir -match '^original') {
            $itemState.Text = T '当前：原版 99' 'Now: original 99'; $itemState.ForeColor = $grey
        } elseif ($ir -match '^applying') {
            $itemState.Text = T '正在应用…' 'Applying…'; $itemState.ForeColor = $grey
        } elseif ($ir) {
            $itemState.Text = (T '应用失败：' 'Failed: ') + $ir; $itemState.ForeColor = [System.Drawing.Color]::Firebrick
        }
    } elseif ($running) {
        $statusDot.ForeColor = [System.Drawing.Color]::FromArgb(220, 150, 30)
        $statusText.Text = T '游戏在运行，但 mod 还没响应' 'Game is running, but the mod has not responded yet'
        $statusDetail.Text = T '刚启动请稍等；一直这样请查看 ue4ss\UE4SS.log' 'Give it a few seconds after launch; if it stays like this, check ue4ss\UE4SS.log'
    } else {
        $statusDot.ForeColor = $grey
        $statusText.Text = T '游戏未运行' 'Game not running'
        $itemState.Text = ''
        $statusDetail.Text = T '设置会保存，下次启动游戏时生效' 'Settings are saved and apply the next time the game starts'
    }
    if (-not $HasItemLimit) { $itemState.Text = T '未安装' 'Not installed'; $itemState.ForeColor = $grey }
}
$pollTimer.Add_Tick({ Update-State })

Show-Config (Read-Config)
if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Config (Collect-Config) }
$script:lastSeenConfig = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
$pollTimer.Start()
$cbLang.Add_SelectedIndexChanged({
    if ($script:loading) { return }
    $saveTimer.Stop()
    try { Write-Config (Collect-Config); $script:dirty = $false } catch {}
    $newLang = $LangCodes[[Math]::Max(0, $cbLang.SelectedIndex)]
    if ($newLang -eq 'auto') { $newLang = if ([Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*') { 'zh' } else { 'en' } }
    if ($newLang -eq $Lang) { return }
    # Hand the single-instance lock to the new window, then close this one.
    try { $script:instanceMutex.ReleaseMutex(); $script:instanceMutex.Dispose() } catch {}
    # Start PowerShell directly (no shell/console window); ShellExecute here left the new process hung.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $PSHOME 'powershell.exe'
    $psi.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Reopened" + $(if ($FromGame) { ' -FromGame' } else { '' })
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
    $script:closingForLang = $true
    $form.Close()
})

$form.Add_Shown({
    # The hidden-console launcher can start the form minimized; force it back.
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    if ($Reopened -or -not $FromGame) { $form.Activate() }  # don't pull focus away from the game
    foreach ($tb in $sliders.Values) { $tb.Invalidate(); $tb.Update() }
    Update-State
})
$form.Add_FormClosing({
    if ($script:capture) { Stop-Capture }
    if ($script:dirty) { $saveTimer.Stop(); try { Write-Config (Collect-Config) } catch {} }
})
[void]$form.ShowDialog()
