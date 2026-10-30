#Requires -Version 5.1
<#
.SYNOPSIS
    校园网自动认证工具（HTTP 静默登录版，零依赖，适用于 Windows PowerShell 5.1+）
.DESCRIPTION
    1) 探测是否被校园网强制门户拦截（访问连通性检测地址，检查是否被重定向/内容被替换）
    2) 若需要认证：自动获取认证页面地址，解析登录表单，静默提交 账号+密码+运营商
    3) 等待 wait_seconds 秒后复检网络，失败自动重试
    用法:
        autologin.ps1              单次运行（默认）
        autologin.ps1 -Mode monitor  后台监控：网络连接状态变化时自动认证
.PARAMETER Mode
    once    单次检测并（如需要）登录
    monitor 持续监控网络状态变化，自动触发认证
#>
[CmdletBinding()]
param(
    [ValidateSet('once', 'monitor')]
    [string]$Mode = 'once',
    [string]$ConfigPath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
$LogDir     = Join-Path $ScriptDir 'logs'
$DebugDir   = Join-Path $ScriptDir 'debug'
$LogFile    = Join-Path $LogDir 'autologin.log'
$PidFile    = Join-Path $ScriptDir 'monitor.pid'
if (-not (Test-Path -LiteralPath $LogDir))   { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $DebugDir)) { New-Item -ItemType Directory -Path $DebugDir -Force | Out-Null }

$script:DebugEnabled = $false

# ---------------------------------------------------------------- 日志
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Quiet) {
        $color = 'Gray'
        switch ($Level) {
            'WARN'  { $color = 'Yellow' }
            'ERROR' { $color = 'Red' }
            'DEBUG' { $color = 'DarkGray' }
        }
        Write-Host $line -ForegroundColor $color
    }
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Save-DebugFile {
    param([string]$Prefix, [string]$Extension, [string]$Content)
    if (-not $script:DebugEnabled) { return }
    $name = '{0}_{1}{2}' -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss'), $Extension
    try { [System.IO.File]::WriteAllText((Join-Path $DebugDir $name), $Content, [System.Text.Encoding]::UTF8) } catch { }
}

# ---------------------------------------------------------------- 配置
function Get-CfgValue {
    param($Object, [string]$Name, $DefaultValue)
    if ($null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name) -and ($null -ne $Object.$Name)) {
        return $Object.$Name
    }
    return $DefaultValue
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "找不到配置文件: $ConfigPath"
    }
    $raw = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)
    $cfg = $raw | ConvertFrom-Json
    $script:DebugEnabled = [bool](Get-CfgValue $cfg 'debug' $false)
    return $cfg
}

# ---------------------------------------------------------------- HTTP 探测
function Invoke-Probe {
    param([string]$Url, [int]$TimeoutSec)
    $result = [pscustomobject]@{ Url = $Url; Status = -1; Location = $null; Content = ''; Error = $null }
    try {
        # 用 HttpWebRequest 而不是 Invoke-WebRequest：
        # PS 5.1 的 IWR -MaximumRedirection 0 会丢掉 Location 头，无法发现认证页地址
        $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Url)
        $req.Method = 'GET'
        $req.AllowAutoRedirect = $false
        $req.Timeout = [Math]::Max(1000, $TimeoutSec * 1000)
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Microsoft Windows Detection'
        try { $req.Proxy = $null } catch { }   # 不走系统代理，避免代理干扰判断
        $resp = $null
        try {
            $resp = $req.GetResponse()
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { $resp = $_.Exception.Response } else { throw }
        }
        $result.Status = [int]$resp.StatusCode
        $loc = $resp.Headers['Location']
        if ($loc) { $result.Location = [string]$loc }
        try {
            $stream = $resp.GetResponseStream()
            if ($stream) {
                $sr = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $text = $sr.ReadToEnd()
                $sr.Close()
                if ($text.Length -le 65536) { $result.Content = $text }   # 太大的非网页内容忽略
            }
        } catch { }
        $resp.Close()
    } catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Resolve-Url {
    param([string]$Base, [string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative)) { return $null }
    try { return ([System.Uri]::new([System.Uri]$Base, $Relative)).AbsoluteUri } catch { return $Relative }
}

function Find-PortalLink {
    # 从被替换成认证页的 HTML 中猜认证页面地址
    param([string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return $null }
    $m = [regex]::Match($Html, '(?i)https?://[^"''\s<>]*portalReceiveAction\.do[^"''\s<>]*')
    if ($m.Success) { return $m.Value.Trim() }
    $m = [regex]::Match($Html, '(?i)http-equiv\s*=\s*["'']?refresh["'']?[^>]*url\s*=\s*([^""''>]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim().Trim('"', "'") }
    $m = [regex]::Match($Html, '(?i)location(?:\.href)?\s*=\s*["'']([^""'']+)["'']')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    $m = [regex]::Match($Html, '(?i)https?://[^\s""''<>]*:6060/[^\s""''<>]*')
    if ($m.Success) { return $m.Value.Trim() }
    return $null
}

function Get-NetworkState {
    # 返回 @{ Online; Captive; PortalUrl; Detail }
    param($Cfg)
    $timeout = [int](Get-CfgValue $Cfg 'timeout_seconds' 10)
    $probes  = @(Get-CfgValue $Cfg 'detection_urls' @())
    if ($probes.Count -eq 0) {
        $probes = @(
            @{ url = 'http://www.msftconnecttest.com/connecttest.txt'; expect = 'Microsoft Connect Test' },
            @{ url = 'http://connect.rom.miui.com/generate_204';        expect_status = 204 },
            @{ url = 'http://captive.apple.com/hotspot-detect.html';   expect = 'Success' }
        )
    }
    $lastDetail = ''
    foreach ($p in $probes) {
        $url = [string](Get-CfgValue $p 'url' '')
        if (-not $url) { continue }
        $r = Invoke-Probe -Url $url -TimeoutSec $timeout
        if ($r.Status -eq -1) {
            $lastDetail = "探测失败 $url : $($r.Error)"
            Write-Log $lastDetail 'DEBUG'
            continue
        }
        # 被重定向：若跳到非检测地址 => 强制门户
        if ($r.Location) {
            $abs = Resolve-Url -Base $url -Relative $r.Location
            if ($abs -match '(?i)msftconnecttest\.com|connecttest|generate_204|hotspot-detect|gstatic\.com|nmstool|connectivitycheck') {
                Write-Log "探测 $url 被重定向到另一检测地址，跳过" 'DEBUG'
                continue
            }
            Write-Log "检测到强制门户，认证页面: $abs"
            return [pscustomobject]@{ Online = $false; Captive = $true; PortalUrl = $abs; Detail = "重定向自 $url" }
        }
        # 期望状态码 / 期望内容 => 在线
        $expectStatus = Get-CfgValue $p 'expect_status' $null
        if ($null -ne $expectStatus -and $r.Status -eq [int]$expectStatus) {
            return [pscustomobject]@{ Online = $true; Captive = $false; PortalUrl = $null; Detail = "$url -> $([int]$r.Status)" }
        }
        $expect = Get-CfgValue $p 'expect' $null
        if ($expect -and $r.Content -match [regex]::Escape([string]$expect)) {
            return [pscustomobject]@{ Online = $true; Captive = $false; PortalUrl = $null; Detail = "$url 内容匹配" }
        }
        if (-not $expect -and -not $expectStatus) { continue }
        # 200 但内容不是预期 => 页面被替换为认证页
        $link = Find-PortalLink -Html $r.Content
        Write-Log "检测到强制门户（内容被替换）自 $url"
        return [pscustomobject]@{ Online = $false; Captive = $true; PortalUrl = $link; Detail = "内容替换自 $url" }
    }
    return [pscustomobject]@{ Online = $false; Captive = $false; PortalUrl = $null; Detail = $lastDetail }
}

# ---------------------------------------------------------------- 网络签名（用于感知连接状态变化）
function Get-IPv4Signature {
    $ips = @()
    try {
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -ExpandProperty IPAddress | Sort-Object)
    } catch { }
    return ($ips -join ',')
}

function Get-Ssid {
    try {
        $out = & netsh wlan show interfaces 2>$null
        foreach ($line in $out) {
            if ($line -match '^\s*(?:SSID|SSID\s*\d*)\s*:\s*(.+?)\s*$' -and $Matches[1] -notlike '*<*') { return $Matches[1] }
        }
    } catch { }
    return ''
}

function Get-NetworkSignature { return '{0}|{1}' -f (Get-IPv4Signature), (Get-Ssid) }

# ---------------------------------------------------------------- 表单解析
function Get-InputFields {
    param([string]$Html)
    $list = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($m in [regex]::Matches($Html, '<input\b[^>]*?>', 'IgnoreCase')) {
        $attrs = @{}
        foreach ($a in [regex]::Matches($m.Value, '([\w:.-]+)\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))', 'IgnoreCase')) {
            $key = $a.Groups[1].Value.ToLower()
            $val = if ($a.Groups[2].Success) { $a.Groups[2].Value } elseif ($a.Groups[3].Success) { $a.Groups[3].Value } else { $a.Groups[4].Value }
            $attrs[$key] = $val
        }
        [void]$list.Add([pscustomobject]@{
            Index       = $i
            Pos         = $m.Index
            Tag         = $m.Value
            Type        = if ($attrs.ContainsKey('type')) { $attrs['type'].ToLower() } else { '' }
            Name        = if ($attrs.ContainsKey('name'))  { $attrs['name'] }  else { '' }
            Value       = if ($attrs.ContainsKey('value')) { $attrs['value'] } else { '' }
            Placeholder = if ($attrs.ContainsKey('placeholder')) { $attrs['placeholder'] } else { '' }
        })
        $i++
    }
    return $list
}

function Get-IspSelection {
    # 返回 @{ Field; Value; How }；找不到返回 Field=$null
    param([string]$Html, $InputFields, [string]$Isp, $CfgForm)
    $cfgField = [string](Get-CfgValue $CfgForm 'isp_field' 'auto')
    $cfgValue = [string](Get-CfgValue $CfgForm 'isp_value' 'auto')
    if ($cfgField -ne 'auto' -and $cfgValue -ne 'auto') {
        return @{ Field = $cfgField; Value = $cfgValue; How = 'config' }
    }
    $keywords = @{
        'local'   = @('local', 'campus', '校园网', '本地', ' intranet')
        'telecom' = @('telecom', 'dx', 'tele', 'ctcc', '163', '电信', 'china telecom')
        'mobile'  = @('cmcc', 'mobile', 'yd', 'cm', '移动', 'china mobile')
        'unicom'  = @('unicom', 'lt', 'wo', '联通', 'china unicom')
    }
    $kws = $keywords[$Isp]
    if (-not $kws) { $kws = $keywords['telecom'] }

    # 取某个单选框自己的标签文字（到下一个 <input 之前为止，避免读到相邻选项的标签）
    function Get-RadioContext {
        param($Field, [string]$FullHtml)
        $start = $Field.Pos
        if ($start -lt 0 -or $start -gt $FullHtml.Length) { return '' }
        $len = [Math]::Min(160, $FullHtml.Length - $start)
        $chunk = $FullHtml.Substring($start, $len)
        $nextIdx = $chunk.IndexOf('<input', 1, [System.StringComparison]::OrdinalIgnoreCase)
        if ($nextIdx -gt 0) { $chunk = $chunk.Substring(0, $nextIdx) }
        return ($chunk -replace '<[^>]+>', ' ')
    }

    # 1) 单选按钮组：按 值 / 标签文字 关键字匹配
    $radios = @($InputFields | Where-Object { $_.Type -eq 'radio' -and $_.Name })
    $groups = @($radios | Group-Object Name)
    foreach ($g in $groups) {
        foreach ($f in $g.Group) {
            $ctx  = Get-RadioContext -Field $f -FullHtml $Html
            $hay  = ('{0} {1} {2}' -f $f.Value, $f.Tag, $ctx).ToLower()
            foreach ($kw in $kws) { if ($hay -like "*$($kw.ToLower())*") { return @{ Field = [string]$g.Name; Value = [string]$f.Value; How = 'keyword' } } }
        }
    }
    # 2) 兜底：三个选项的一组 => 按页面顺序 移动/联通/电信 定位（local 无法按顺序猜，直接跳过）
    if ($Isp -ne 'local') {
        $orderIndex = @{ 'mobile' = 0; 'unicom' = 1; 'telecom' = 2 }
        foreach ($g in $groups) {
            $vals = @($g.Group | ForEach-Object { [string]$_.Value })
            if ($vals.Count -ge 3) {
                $idx = [int]$orderIndex[$Isp]
                if ($idx -ge $vals.Count) { $idx = $vals.Count - 1 }
                return @{ Field = [string]$g.Name; Value = $vals[$idx]; How = 'order-fallback' }
            }
        }
    }
    # 3) 下拉框
    foreach ($m in [regex]::Matches($Html, '(?is)<select\b[^>]*name\s*=\s*["'']([^"'']+)["''][^>]*>(.*?)</select>')) {
        $selName = $m.Groups[1].Value
        $inner   = $m.Groups[2].Value
        foreach ($om in [regex]::Matches($inner, '(?is)<option\b[^>]*value\s*=\s*["'']([^"'']*)["''][^>]*>(.*?)</option>')) {
            $val   = $om.Groups[1].Value
            $label = ($om.Groups[2].Value -replace '<[^>]+>', '').Trim()
            foreach ($kw in $kws) {
                if ("$val $label" -like "*$($kw.ToLower())*") { return @{ Field = $selName; Value = $val; How = 'select' } }
            }
        }
    }
    return @{ Field = $null; Value = $null; How = 'none' }
}

# ---------------------------------------------------------------- 登录
function ConvertTo-HtmlText {
    # 门户常不带 charset 声明，Invoke-WebRequest 会把响应体当作 byte[] 返回。
    # 直接 [string] 强转会退化成"十进制字节码序列"，必须显式按 UTF-8 解码。
    param($Content)
    if ($null -eq $Content) { return '' }
    if ($Content -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($Content) }
    if ($Content -is [System.Collections.IEnumerable] -and $Content -isnot [string]) {
        $bytes = @($Content)
        if ($bytes.Count -gt 0 -and $bytes[0] -is [byte]) { return [System.Text.Encoding]::UTF8.GetString([byte[]]$bytes) }
    }
    return [string]$Content
}

function Invoke-PortalLogin {
    # 河南工学院锐捷门户专用登录，精确复刻页面 JS 流程：
    #   1) GET PortalJsonAction.do 取一次性认证参数（timestamp/uuid/serverip/authByRas 等）
    #   2) 账号拼运营商后缀（账号@gxydx 等）
    #   3) GET /quickauth.do 提交 userid/passwd/... 认证
    #   4) 判响应 code == "0"
    param($Cfg, [string]$PortalUrl)

    $timeout  = [int](Get-CfgValue $Cfg 'timeout_seconds' 10)
    $account  = [string](Get-CfgValue $Cfg 'account' '')
    $password = [string](Get-CfgValue $Cfg 'password' '')
    $isp      = [string](Get-CfgValue $Cfg 'isp' 'telecom')

    $ua      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    # 从认证地址解析出 wlanuserip / wlanacname（浏览器重定向时已带上）
    $parsed = $null
    try { $parsed = [System.Uri]$PortalUrl } catch { }
    $wlanuserip = ''; $wlanacname = ''
    if ($parsed) {
        # 注意 System.Uri 的 Query 含开头的 '?'，需先去掉再按 & 拆分
        $query = $parsed.Query
        if ($query.StartsWith('?')) { $query = $query.Substring(1) }
        foreach ($mm in [regex]::Matches($query, '([^&=]+)=([^&]*)')) {
            $k = [uri]::UnescapeDataString($mm.Groups[1].Value)
            $v = [uri]::UnescapeDataString($mm.Groups[2].Value)
            if ($k -ieq 'wlanuserip')  { $wlanuserip = $v }
            if ($k -ieq 'wlanacname')  { $wlanacname = $v }
        }
    }
    if (-not $wlanuserip -or -not $wlanacname) {
        throw "认证地址缺少 wlanuserip/wlanacname，无法认证: $PortalUrl"
    }

    # 1) 打开认证页面（建立 Cookie）
    Write-Log "打开认证页面: $PortalUrl"
    $page = Invoke-WebRequest -Uri $PortalUrl -UseBasicParsing -UserAgent $ua -WebSession $session -TimeoutSec $timeout
    $html = ConvertTo-HtmlText -Content $page.Content
    Save-DebugFile -Prefix 'login_page' -Extension '.html' -Content $html

    # 用 Authority（含非默认端口）构造门户根地址
    $portalBase = '{0}://{1}' -f $parsed.Scheme, $parsed.Authority

    # 2) 取一次性认证参数
    $qs      = 'wlanuserip={0}&wlanacname={1}' -f [uri]::EscapeDataString($wlanuserip), [uri]::EscapeDataString($wlanacname)
    $jsonUrl = "$portalBase/PortalJsonAction.do?$qs&viewStatus=1"
    Write-Log "拉取认证配置: $jsonUrl" 'DEBUG'
    $jresp  = Invoke-WebRequest -Uri $jsonUrl -UseBasicParsing -UserAgent $ua -WebSession $session `
                 -Headers @{ Referer = $PortalUrl } -TimeoutSec $timeout
    $jtext  = ConvertTo-HtmlText -Content $jresp.Content
    Save-DebugFile -Prefix 'portal_json' -Extension '.json' -Content $jtext
    $conf = $null
    try { $conf = $jtext | ConvertFrom-Json } catch { throw "PortalJsonAction.do 返回的不是合法 JSON，见 debug 目录" }
    if ($null -eq $conf) { throw 'PortalJsonAction.do 配置为空' }

    $serverip   = ''; if ($conf.serverForm) { $serverip = [string]$conf.serverForm.serverip }
    $portalVer  = ''; if ($conf.serverForm) { $portalVer = [string]$conf.serverForm.portalVer }
    $timestamp  = ''; $uuid = ''; $pageid = ''
    if ($conf.portalconfig) {
        $timestamp = [string]$conf.portalconfig.timestamp
        $uuid      = [string]$conf.portalconfig.uuid
        $pageid    = [string]$conf.portalconfig.id
    }
    # portalForm 里的值优先于 URL 参数（与页面 JS 一致）
    if ($conf.portalForm) {
        if ($conf.portalForm.wlanuserip) { $wlanuserip = [string]$conf.portalForm.wlanuserip }
        if ($conf.portalForm.wlanacname) { $wlanacname = [string]$conf.portalForm.wlanacname }
    }
    $authByRas = $false
    if ($conf.PSObject.Properties.Name -contains 'authByRas') { $authByRas = [bool]$conf.authByRas }

    # 3) 运营商后缀（common.js 里写死的映射）
    $suffixMap = Get-CfgValue $Cfg 'isp_suffix' $null
    $suffix = ''
    if ($suffixMap) { $suffix = [string](Get-CfgValue $suffixMap $isp '') }
    if (-not $suffix) {
        $defaultSuffix = @{ 'local'='@gxylocal'; 'mobile'='@gxyyd'; 'unicom'='@gxylt'; 'telecom'='@gxydx' }
        if ($defaultSuffix.ContainsKey($isp)) { $suffix = $defaultSuffix[$isp] }
    }
    $fullAccount = $account + $suffix
    Write-Log ("账号={0} 运营商={1} 后缀='{2}' -> 提交账号={3}" -f $account, $isp, $suffix, $fullAccount)

    if ($authByRas) {
        Write-Log '门户要求 RSA 加密（authByRas=true），纯 HTTP 无法完成，请告知 AI 改用浏览器方式' 'ERROR'
        return $false
    }

    # 4) 组装 quickauth 参数（与 portalUtil.js 的 postdata 一致）
    $qa = @{}
    $qa['userid']        = $fullAccount
    $qa['passwd']        = $password
    $qa['wlanuserip']    = $wlanuserip
    $qa['wlanacname']    = $wlanacname
    $qa['wlanacIp']      = $serverip
    $qa['ssid']          = ''
    $qa['vlan']          = ''
    $qa['mac']           = ''
    $qa['version']       = $portalVer
    $qa['portalpageid']  = $pageid
    $qa['validateCode']  = ''
    $qa['timestamp']     = $timestamp
    $qa['uuid']          = $uuid
    $qa['portaltype']    = '0'
    $qa['hostname']      = ''
    $qa['bindCtrlId']    = ''
    $extra = Get-CfgValue $Cfg 'form_extra_fields' $null
    if ($extra) { foreach ($pr in $extra.PSObject.Properties) { $qa[$pr.Name] = [string]$pr.Value } }

    $pairs = @()
    foreach ($key in $qa.Keys) { $pairs += ('{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString([string]$qa[$key])) }
    $qaUrl = "$portalBase/quickauth.do?" + ($pairs -join '&')
    Write-Log "提交认证: $qaUrl" 'DEBUG'

    # 5) 提交认证（不跟随重定向：认证成功/失败常以 302 表达，跟随会把结果冲掉）
    try {
        $resp = Invoke-WebRequest -Uri $qaUrl -Method Get -UseBasicParsing -UserAgent $ua -WebSession $session `
                    -Headers @{ Referer = $PortalUrl } -TimeoutSec $timeout -MaximumRedirection 0 -ErrorAction Stop
        $respText = ConvertTo-HtmlText -Content $resp.Content
        $status   = [int]$resp.StatusCode
    } catch {
        $er = $_.Exception.Response
        if ($er) {
            $status   = [int]$er.StatusCode
            $respText = ''
            $loc = ''
            try { $loc = [string]$er.Headers['Location'] } catch { }
            Write-Log "认证返回 HTTP $status 重定向到: $loc" 'DEBUG'
        } else {
            throw
        }
    }
    Save-DebugFile -Prefix 'quickauth_response' -Extension '.json' -Content $respText

    # 认证成功常表现为 302 跳转（重定向即代表放行）；200 则看 JSON 的 code
    $code = $null; $msg = ''
    if ($respText) {
        try { $rj = $respText | ConvertFrom-Json; if ($rj.PSObject.Properties.Name -contains 'code') { $code = [string]$rj.code } } catch { }
        try { $rj2 = $respText | ConvertFrom-Json; if ($rj2.PSObject.Properties.Name -contains 'msg') { $msg = [string]$rj2.msg } } catch { }
    }
    Write-Log ("认证响应: HTTP={0} code='{1}' msg='{2}'" -f $status, $code, $msg)
    if ($status -eq 302 -or $status -eq 301 -or $status -eq 303 -or $status -eq 307) { return $true }
    if ($code -eq '0') { return $true }
    if ($msg) { Write-Log "门户返回: $msg" 'WARN' }
    return $false
}

# ---------------------------------------------------------------- 主流程
function Invoke-LoginFlow {
    param($Cfg)

    $state = Get-NetworkState -Cfg $Cfg
    if ($state.Online) { Write-Log "网络在线，无需认证（$($state.Detail)）"; return $true }
    if ($state.Detail) { Write-Log "探测详情: $($state.Detail)" 'DEBUG' }

    $portalUrl = $state.PortalUrl
    if (-not $portalUrl) {
        $portalUrl = [string](Get-CfgValue $Cfg 'portal_fallback_url' '')
        if ($portalUrl) { Write-Log "未捕获到重定向地址，使用配置中的备用认证地址（注意 wlanuserip 可能已变化）" 'WARN' }
    }
    if (-not $portalUrl) { Write-Log '未能确定认证页面地址，无法登录' 'ERROR'; return $false }

    $ok = $false
    try { $ok = Invoke-PortalLogin -Cfg $Cfg -PortalUrl $portalUrl } catch {
        Write-Log "登录请求异常: $($_.Exception.Message)" 'ERROR'
    }
    if (-not $ok) { Write-Log '认证未成功（详见上方响应 code/msg 与 debug 目录）' 'ERROR'; return $false }

    $wait = [int](Get-CfgValue $Cfg 'wait_seconds' 5)
    Write-Log "等待 $wait 秒后验证网络..."
    Start-Sleep -Seconds $wait

    $after = Get-NetworkState -Cfg $Cfg
    if ($after.Online) { Write-Log '登录成功，网络已可用 ✔'; return $true }
    Write-Log '登录后仍无法访问外网' 'ERROR'
    return $false
}

function Start-Once {
    $Cfg = Read-Config
    if (-not (([string](Get-CfgValue $Cfg 'account' '')).Trim()))  { Write-Log '请先在 config.json 中填写 account（账号）' 'ERROR'; return }
    if (-not (([string](Get-CfgValue $Cfg 'password' '')).Trim())) { Write-Log '请先在 config.json 中填写 password（密码）' 'ERROR'; return }
    $retries = [int](Get-CfgValue $Cfg 'retries' 3)
    $delay   = [int](Get-CfgValue $Cfg 'retry_delay_seconds' 3)
    for ($i = 1; $i -le $retries; $i++) {
        Write-Log "===== 第 $i/$retries 次认证尝试 ====="
        try { if (Invoke-LoginFlow -Cfg $Cfg) { return } } catch { Write-Log "流程异常: $($_.Exception.Message)" 'ERROR' }
        if ($i -lt $retries) { Start-Sleep -Seconds $delay }
    }
    Write-Log "认证失败。若一直失败，请把 $DebugDir 下的文件发给 AI 分析。" 'ERROR'
}

function Start-MonitorLoop {
    $Cfg = Read-Config
    if (-not (([string](Get-CfgValue $Cfg 'password' '')).Trim())) { Write-Log 'config.json 中未填写 password，监控无法完成登录' 'ERROR' }
    $checkInterval = [int](Get-CfgValue $Cfg 'check_interval_seconds' 3)
    $periodic      = [int](Get-CfgValue $Cfg 'periodic_check_seconds' 300)
    if ($checkInterval -lt 1) { $checkInterval = 3 }
    Set-Content -LiteralPath $PidFile -Value $PID -Encoding ASCII
    Write-Log "后台监控已启动 (PID $PID)，网络状态变化将自动认证"
    $lastSig   = Get-NetworkSignature
    $lastCheck = Get-Date
    Write-Log "当前网络特征: $lastSig"
    try {
        while ($true) {
            Start-Sleep -Seconds $checkInterval
            $sig = Get-NetworkSignature
            if ($sig -ne $lastSig) {
                Write-Log "检测到网络连接状态变化: $sig"
                $lastSig = $sig
                $lastCheck = Get-Date
                Start-Sleep -Seconds 3   # 等待链路/DHCP 稳定
                try { Start-Once } catch { Write-Log "监控触发异常: $($_.Exception.Message)" 'ERROR' }
            } elseif ($periodic -gt 0 -and ((Get-Date) - $lastCheck).TotalSeconds -ge $periodic) {
                $lastCheck = Get-Date
                Write-Log '周期性复检网络状态'
                try { Start-Once } catch { Write-Log "周期检查异常: $($_.Exception.Message)" 'ERROR' }
            }
        }
    } finally {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Write-Log '后台监控已退出'
    }
}

# ---------------------------------------------------------------- 入口
try {
    if ($Mode -eq 'monitor') { Start-MonitorLoop } else { Start-Once }
} catch {
    Write-Log "程序异常: $($_.Exception.Message)" 'ERROR'
}
