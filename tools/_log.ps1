# WitcherPadBridge -- shared installer transcript (PowerShell half of tools/_log.sh).
#
# Everything an installer prints also lands in <game>\WitcherPadBridge\install.log. A report from
# a machine nobody here can touch is otherwise just "не работает"; this file says which build,
# which folder, what was copied over what, and which step ran last.
#
# Not Start-Transcript: it fails outright in hosts that do not implement it, and taking the
# installer down with it would be a poor trade for a log file.

$script:WxpLogFile = ""
$script:WxpRoot    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

function Get-WxpVersion {
    $v = Join-Path $script:WxpRoot "VERSION"
    if (Test-Path $v) { return (Get-Content $v -Raw).Trim() }
    return "dev"
}

function Open-WxpLog([string]$Game, [string]$Label) {
    if (-not $Game) { return }
    try {
        $dir = Join-Path $Game "WitcherPadBridge"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $script:WxpLogFile = Join-Path $dir "install.log"
        $os = try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { [System.Environment]::OSVersion.VersionString }
        @(
            ""
            "==== $Label   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   version $(Get-WxpVersion) ===="
            "     host    $os / PowerShell $($PSVersionTable.PSVersion)"
            "     game    $Game"
            "     package $script:WxpRoot"
        ) | Add-Content -Path $script:WxpLogFile -Encoding UTF8
    } catch { $script:WxpLogFile = "" }
}

function Say([string]$Text, [string]$Color = "") {
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    Note $Text
}

function Note([string]$Text) {
    if (-not $script:WxpLogFile) { return }
    try { Add-Content -Path $script:WxpLogFile -Value ("  " + $Text) -Encoding UTF8 } catch { }
}

function Fail([string]$Text) {
    Note ("FAILED: " + $Text)
    throw $Text
}

# Sizes, not just names: this is what tells a stale copy from a fresh one, which otherwise looks
# exactly like "the mod does not work".
function Write-WxpFiles([string[]]$Paths) {
    if (-not $script:WxpLogFile) { return }
    Note "result:"
    foreach ($p in $Paths) {
        if (Test-Path $p) { Note ("  {0,10} bytes  {1}" -f (Get-Item $p).Length, $p) }
        else              { Note ("  {0,10}        {1}" -f "MISSING", $p) }
    }
}
