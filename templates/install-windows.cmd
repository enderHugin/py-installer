:: install-windows.cmd
@echo off
rem Instalador para Windows generado por py-installer (no necesita administrador ni tener Python instalado).
rem Este archivo es un .cmd con un script de PowerShell dentro: lo extrae y lo ejecuta.
title __PYI_TITLE__
set "PYI_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:PYI_SELF); $i=$t.IndexOf('#'+'#PS##'); $p=Join-Path $env:TEMP '__PYI_ID__-setup.ps1'; [IO.File]::WriteAllText($p,$t.Substring($i),(New-Object Text.UTF8Encoding $true)); & powershell -NoProfile -ExecutionPolicy Bypass -File $p %*; exit $LASTEXITCODE"
set "PYI_RC=%ERRORLEVEL%"
if not "%PYI_RC%"=="0" if not defined PYI_NO_PAUSE pause
exit /b %PYI_RC%
##PS##
# ---------------------------------------------------------------------------------------------
# Instalador de Windows (py-installer).
# Todo va a carpetas del usuario (sin administrador): consigue un Python propio con "uv" (no toca
# el Python que tengas instalado, si es que tienes alguno), prepara su entorno y deja el programa
# instalado con sus accesos directos, su icono y su entrada en "Aplicaciones instaladas".
# Volver a ejecutarlo actualiza. Para quitarlo: desde "Aplicaciones instaladas" de Windows, o
# ejecutando este archivo con "desinstalar".
# Variables opcionales (se ponen con "set" en una ventana de comandos y se ejecuta el instalador desde ahi):
#   <PREFIJO>_INSTALL_DIR=D:\carpeta   instalar en otra carpeta/unidad
#   <PREFIJO>_NO_LAUNCH=1              no abrir el programa al terminar
#   <PREFIJO>_BASE_URL=https://...     descargar el programa de otra direccion (pruebas)
# ---------------------------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# @@PYI_CONFIG@@

# textos en el idioma de este instalador ($Lang, $L: los pone py-installer desde lang/pyi.<idioma>.json)
function T([string]$k, [hashtable]$v = @{}) {
    $s = $L[$k]
    if ($null -eq $s) { $s = $k }
    foreach ($n in $v.Keys) { $s = $s.Replace('{' + $n + '}', [string]$v[$n]) }
    return $s
}

function EnvOpt([string]$suffix) { return [Environment]::GetEnvironmentVariable($EnvPrefix + '_' + $suffix) }
if (EnvOpt 'BASE_URL') { $Base = (EnvOpt 'BASE_URL').TrimEnd('/') }
$Dl = $Base + '/dl'
if (EnvOpt 'INSTALL_DIR') {
    $Root = Join-Path (EnvOpt 'INSTALL_DIR') 'data'
    $Prog = Join-Path (EnvOpt 'INSTALL_DIR') 'app'
} else {
    $Root = Join-Path $env:LOCALAPPDATA $Folder
    $Prog = Join-Path $env:LOCALAPPDATA ('Programs\' + $Folder)
}
$Bin    = Join-Path $Root 'bin'
$Rt     = Join-Path $Root 'runtime'
$Stage  = Join-Path $Root 'stage'
$RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $AppId
$Total  = 5
$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'instalacion.log'
try { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; Start-Transcript -Path $LogFile -Append -Force | Out-Null } catch { }

function Step([int]$n, [string]$text) {
    Write-Host ''
    Write-Host ("[{0}/{1}] {2}" -f $n, $Total, $text) -ForegroundColor Cyan
}
function Say([string]$text) { Write-Host ('      ' + $text) }

function Get-File([string]$url, [string]$dest, [int]$timeoutSec = 180) {
    # Invoke-WebRequest puede quedarse colgado sin fallar si la conexion se atasca a medias: se
    # lanza en un job con limite de tiempo real (3 intentos, espera creciente) y se va avisando de
    # lo descargado para que no parezca colgado mientras avanza.
    $last = $null
    $dir = Split-Path -Parent $dest
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    for ($try = 1; $try -le 3; $try++) {
        if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
        $job = $null
        try {
            $job = Start-Job -ScriptBlock {
                param($u, $d)
                $ProgressPreference = 'SilentlyContinue'
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
                Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $d
            } -ArgumentList $url, $dest
            $deadline = (Get-Date).AddSeconds($timeoutSec)
            $lastMb = -1
            while ($job.State -eq 'Running' -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
                if (Test-Path $dest) {
                    $mb = [math]::Floor((Get-Item $dest).Length / 1MB)
                    if ($mb -gt $lastMb -and $mb -gt 0) { Say ('... ' + $mb + ' MB'); $lastMb = $mb }
                }
            }
            if ($job.State -eq 'Running') {
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                throw (T 'inst.dl_timeout' @{ s = $timeoutSec })
            }
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
            if ((Get-Item $dest -ErrorAction SilentlyContinue).Length -gt 0) { return }
            throw (T 'inst.dl_empty')
        } catch {
            $last = $_
        } finally {
            if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }
        Start-Sleep -Seconds (2 * $try)
    }
    throw (T 'inst.dl_failed' @{ url = $url; error = $last })
}

function Run-Native([string]$exe, [string[]]$nativeArgs) {
    # Con $ErrorActionPreference = 'Stop', cualquier linea de un programa nativo por stderr tira
    # abajo el instalador mostrando solo esa primera linea. Aqui se baja la guardia un momento para
    # leer el fallo entero y decidir que hacer.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $exe @nativeArgs 2>&1 | ForEach-Object { [string]$_ }; $rc = $LASTEXITCODE } catch { $o = @([string]$_); $rc = 99 }
    $ErrorActionPreference = $old
    return @{ rc = $rc; out = @($o) }
}
function Tail($r, [int]$n = 4) { return (($r.out | Where-Object { $_.Trim() } | Select-Object -Last $n) -join ' | ') }

function Stop-Running {
    try {
        $pat = '*' + [Management.Automation.WildcardPattern]::Escape($Prog) + '*' + [Management.Automation.WildcardPattern]::Escape($Entry) + '*'
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.Name -like 'python*' -and $_.CommandLine -like $pat -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Show-Box([string]$text, [string]$icon) {
    if (EnvOpt 'NO_LAUNCH') { return }   # instalacion desatendida: sin ventanas que esperen un clic
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($text, $AppName, 'OK', $icon)
    } catch { }
}

function Expand-Picked([string]$archive, [string[]]$names, [string]$destDir) {
    # Saca de un .zip (o .tar.gz) solo los archivos con esos nombres, esten en la subcarpeta que esten.
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $got = @()
    if ($archive -match '\.zip$') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($archive)
        try {
            foreach ($n in $names) {
                $e = $z.Entries | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                if ($e) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $destDir $n), $true); $got += $n }
            }
        } finally { $z.Dispose() }
    } else {
        $tmp = $archive + '.d'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        & tar.exe -xzf $archive -C $tmp
        foreach ($n in $names) {
            $f = Get-ChildItem -Path $tmp -Recurse -File -Filter $n | Select-Object -First 1
            if ($f) { Copy-Item $f.FullName (Join-Path $destDir $n) -Force; $got += $n }
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $got
}

# ---- "desinstalar" directo (sin pasar por el Panel de control) --------------------------------
if ($args.Count -ge 1 -and $args[0] -eq 'desinstalar') {
    $u = Join-Path $Root 'uninstall.ps1'
    if (Test-Path $u) { & powershell -NoProfile -ExecutionPolicy Bypass -File $u @($args | Select-Object -Skip 1) }
    else { Write-Host ('  ' + (T 'inst.not_installed' @{ app = $AppName })) }
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

try {
    Write-Host ''
    Write-Host '  ==============================' -ForegroundColor Yellow
    Write-Host ('        ' + $AppName)           -ForegroundColor Yellow
    Write-Host '  ==============================' -ForegroundColor Yellow
    Write-Host ('  ' + (T 'inst.intro1'))
    Write-Host ('  ' + (T 'inst.intro2'))

    Say (T 'inst.log' @{ path = $LogFile })
    Say (T 'inst.sysinfo' @{ win = [Environment]::OSVersion.Version; ps = $PSVersionTable.PSVersion; cpu = $env:PROCESSOR_ARCHITECTURE; user = $env:USERNAME })
    Say (T 'inst.prog_at' @{ path = $Prog })
    Say (T 'inst.lang' @{ lang = $Lang })
    if (-not [Environment]::Is64BitOperatingSystem) { throw (T 'inst.need64' @{ app = $AppName }) }
    New-Item -ItemType Directory -Force -Path $Root, $Bin, $Rt, $Stage, $Prog | Out-Null
    Stop-Running

    try {
        $drive = (Get-Item $Root).PSDrive.Name
        $free = [math]::Floor((Get-PSDrive -Name $drive).Free / 1MB)
        if ($free -lt 700) { Say (T 'inst.low_space' @{ mb = $free; drive = $drive; var = ($EnvPrefix + '_INSTALL_DIR'); folder = $Folder }) }
    } catch { }

    # --- 1) uv: una herramienta de un solo archivo que descarga y gestiona Python -----------------------------------
    Step 1 (T 'inst.step.uv')
    $uv = Join-Path $Bin 'uv.exe'
    $uvOk = $false
    if (Test-Path $uv) { $r = Run-Native $uv @('--version'); $uvOk = ($r.rc -eq 0) }
    if ($uvOk) {
        Say (T 'inst.already')
    } else {
        $zip = Join-Path $Root 'uv.zip'
        # Siempre la de 64 bits Intel/AMD: en Windows ARM funciona emulada y evita librerias que aun no existen para ARM.
        Get-File 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip' $zip
        $tmp = Join-Path $Root 'uv-tmp'
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $found = Get-ChildItem -Path $tmp -Recurse -Filter 'uv.exe' | Select-Object -First 1
        if (-not $found) { throw (T 'inst.no_uv_exe') }
        Copy-Item $found.FullName $uv -Force
        Remove-Item -Recurse -Force $tmp, $zip
        Say (T 'inst.done')
    }

    # --- 2) Python propio (no toca el Python que tengas instalado) --------------------------------------------------
    Step 2 (T 'inst.step.python' @{ ver = $PyVer })
    $env:UV_CACHE_DIR = Join-Path $Root 'cache'
    $env:UV_PYTHON_BIN_DIR = Join-Path $Bin 'python'   # que uv no deje python.exe en ~\.local\bin
    $env:UV_PYTHON_PREFERENCE = 'only-managed'
    $env:UV_PYTHON_DOWNLOADS = 'automatic'
    $env:UV_NO_PROGRESS = '1'
    # uv no lee el proxy de Windows: si PowerShell llega a GitHub por uno, se lo pasamos.
    if (-not ($env:HTTPS_PROXY -or $env:https_proxy)) {
        try {
            $sp = [Net.WebRequest]::GetSystemWebProxy(); $tu = [Uri]'https://github.com'
            if (-not $sp.IsBypassed($tu)) { $pu = $sp.GetProxy($tu); if ($pu -and $pu.AbsoluteUri -ne $tu.AbsoluteUri) { $env:HTTPS_PROXY = $pu.AbsoluteUri; Say (T 'inst.proxy' @{ url = $pu.AbsoluteUri }) } }
        } catch { }
    }
    function Run-Uv([string[]]$uvArgs) {
        $r = Run-Native $uv $uvArgs
        $r.out | ForEach-Object { Write-Host ('      ' + $_) }
        return $r
    }
    $py = $null; $uvTail = ''
    $tries = @(
        @{ n = 'normal'; dir = $Rt; env = @{} },
        @{ n = (T 'inst.try.fresh'); dir = (Join-Path $Root 'py2'); env = @{ UV_SYSTEM_CERTS = '1' } },
        @{ n = (T 'inst.try.slow'); dir = (Join-Path $env:LOCALAPPDATA ($AppId + '-py')); env = @{ UV_SYSTEM_CERTS = '1'; UV_HTTP_TIMEOUT = '300'; UV_CONCURRENT_DOWNLOADS = '1' } }
    )
    foreach ($t in $tries) {
        foreach ($k in $t.env.Keys) { Set-Item -Path ('Env:' + $k) -Value $t.env[$k] }
        if ($t -ne $tries[0]) { Say (T 'inst.retry_with' @{ how = $t.n }) }
        New-Item -ItemType Directory -Force -Path $t.dir | Out-Null
        $env:UV_PYTHON_INSTALL_DIR = $t.dir
        # una carpeta de un intento anterior a medias (sin Lib\os.py) hace que uv falle al escribir dentro de ella
        Get-ChildItem -LiteralPath $t.dir -Directory -Filter ('cpython-' + $PyVer + '*') -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Path (Join-Path $_.FullName 'Lib\os.py')) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        $r = Run-Uv @('python', 'install', $PyVer)
        if ($r.rc -eq 0) {
            $f = Run-Native $uv @('python', 'find', $PyVer)
            if ($f.rc -eq 0 -and $f.out) { $py = ([string]$f.out[0]).Trim(); break }
        }
        $uvTail = Tail $r
        Start-Sleep -Seconds 2
    }
    if (-not $py -or -not (Test-Path $py)) {
        # Plan B: bajar Python con PowerShell (que si respeta tu proxy y tus certificados) y descomprimirlo con tar.
        Say (T 'inst.uv_no_python')
        try {
            $rel = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest'
            $rx = '^cpython-' + [regex]::Escape($PyVer) + '\.\d+\+\d+-x86_64-pc-windows-msvc-install_only(_stripped)?\.tar\.gz$'
            $as = @($rel.assets | Where-Object { $_.name -match $rx }) | Select-Object -First 1
            if (-not $as) { throw (T 'inst.py_none_release' @{ ver = $PyVer }) }
            $tgz = Join-Path $Root 'python.tar.gz'
            Get-File $as.browser_download_url $tgz 480
            $dest = Join-Path $Rt ('manual-' + $PyVer)
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            & tar.exe -xzf $tgz -C $dest
            if ($LASTEXITCODE -ne 0) { throw (T 'inst.tar_failed' @{ rc = $LASTEXITCODE }) }
            Remove-Item $tgz -Force -ErrorAction SilentlyContinue
            $cand = Join-Path $dest 'python\python.exe'
            if (-not (Test-Path $cand)) { throw (T 'inst.no_python_exe') }
            $r = Run-Native $cand @('-c', 'import sys; print(sys.version)')
            if ($r.rc -ne 0) { throw (T 'inst.py_no_start') }
            $py = $cand
        } catch { $uvTail += ' | ' + (T 'inst.direct_dl' @{ error = $_.Exception.Message }) }
    }
    if (-not $py -or -not (Test-Path $py)) {
        throw (T 'inst.no_python' @{ ver = $PyVer; tail = $uvTail })
    }
    Say $py
    if ($CheckCode -match 'tkinter') {
        # comprobacion temprana: mejor saber aqui que el Python descargado trae Tcl/Tk roto que al abrir el programa
        $r = Run-Native $py @('-c', 'import tkinter; tkinter.Tcl()')
        if ($r.rc -ne 0) { throw (T 'inst.no_tk' @{ url = $IssuesUrl }) }
    }

    # --- 3) el programa --------------------------------------------------------------------------------------------
    Step 3 (T 'inst.step.download' @{ app = $AppName })
    foreach ($f in $Files) { Get-File ($Dl + '/' + $f) (Join-Path $Stage $f) }
    Get-File ($Dl + '/VERSION') (Join-Path $Stage 'VERSION')
    if ($HasIco) { try { Get-File ($Dl + '/icon.ico') (Join-Path $Stage 'icon.ico') } catch { Say (T 'inst.no_icon') } }
    if ($DataZip) {
        try {
            $dz = Join-Path $Stage $DataZip
            Get-File ($Dl + '/' + $DataZip) $dz
            Expand-Archive -LiteralPath $dz -DestinationPath (Join-Path $Stage 'data') -Force
            Remove-Item $dz -Force
        } catch { Say (T 'inst.no_data' @{ error = $_.Exception.Message }) }
    }
    $version = (Get-Content (Join-Path $Stage 'VERSION') -Raw).Trim()
    Say (T 'inst.version' @{ v = $version })

    # --- 4) entorno con sus librerias (la parte lenta) --------------------------------------------------------------
    Step 4 (T 'inst.step.install')
    foreach ($f in $Files + @('VERSION')) {
        $dst = Join-Path $Prog $f
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item (Join-Path $Stage $f) $dst -Force
    }
    if (Test-Path (Join-Path $Stage 'icon.ico')) { Copy-Item (Join-Path $Stage 'icon.ico') (Join-Path $Prog 'icon.ico') -Force }
    if (Test-Path (Join-Path $Stage 'data')) {
        # los datos iniciales no pisan lo que ya tengas (una reinstalacion conserva tus cambios)
        Get-ChildItem -LiteralPath (Join-Path $Stage 'data') -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring((Join-Path $Stage 'data').Length).TrimStart('\')
            $dst = Join-Path $Prog $rel
            if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null; Copy-Item $_.FullName $dst }
        }
    }
    $venv = Join-Path $Prog $VenvDir
    $vpy  = Join-Path $venv 'Scripts\python.exe'
    $vpyw = Join-Path $venv 'Scripts\pythonw.exe'
    # un entorno a medias de un intento anterior (sin pythonw.exe, sin pip o con otro Python) se rehace solo
    $venvOk = $false
    if (Test-Path $vpyw) {
        $r = Run-Native $vpy @('-c', ("import pip, sys; assert '%d.%d' % sys.version_info[:2] == '" + $PyVer + "'"))
        if ($r.rc -eq 0) { $venvOk = $true } else { Say (T 'inst.venv_redo') }
    }
    if (-not $venvOk -and (Test-Path $venv)) { Remove-Item -LiteralPath $venv -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $venvOk) {
        # --seed: que incluya pip, para que el programa pueda instalar extras por su cuenta si lo necesita
        $r = Run-Uv @('venv', '--seed', '--python', $py, $venv)
        if ($r.rc -ne 0 -or -not (Test-Path $vpyw)) { throw (T 'inst.venv_fail' @{ tail = (Tail $r) }) }
    } else {
        Say (T 'inst.venv_ok')
    }
    function Install-Pkgs([string[]]$pkgs) {
        $r = Run-Native $uv (@('pip', 'install', '--python', $vpy, '--upgrade', '-q') + $pkgs)
        if ($r.rc -ne 0) {
            # plan B: el pip del propio entorno
            $r = Run-Native $vpy (@('-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir', '-q', '--upgrade') + $pkgs)
        }
        return $r
    }
    if ($Required.Count -gt 0) {
        Say (T 'inst.libs' @{ list = ($Required -join ', ') })
        $r = Install-Pkgs $Required
        if ($r.rc -ne 0) { throw (T 'inst.libs_fail' @{ list = ($Required -join ', '); tail = (Tail $r) }) }
    }
    foreach ($o in $Optional) {
        $r = Install-Pkgs @($o.pkg)
        if ($r.rc -ne 0) { Say (T 'inst.opt_fail' @{ pkg = $o.pkg; why = $o.why; tail = (Tail $r 2) }) }
    }
    foreach ($x in $Extras) {
        $dstDir = Join-Path $Prog $x.to
        $missing = @($x.extract | Where-Object { -not (Test-Path (Join-Path $dstDir $_)) })
        if ($missing.Count -eq 0) { Say (T 'inst.extra_ok' @{ label = $x.label }); continue }
        Say (T 'inst.extra_dl' @{ label = $x.label })
        $ext = if ($x.url -match '\.zip($|\?)') { '.zip' } else { '.tar.gz' }
        $arc = Join-Path $Root ('extra' + $ext)
        try {
            Get-File $x.url $arc 600
            $got = Expand-Picked $arc $x.extract $dstDir
            Remove-Item $arc -Force -ErrorAction SilentlyContinue
            if ($got.Count -lt $x.extract.Count) { throw (T 'inst.extra_missing' @{ list = ((@($x.extract | Where-Object { $got -notcontains $_ })) -join ', ') }) }
        } catch {
            $msg = T 'inst.extra_fail' @{ label = $x.label; error = $_.Exception.Message; url = $x.url; files = ($x.extract -join ', '); dir = $dstDir }
            if ($x.required) { throw $msg } else { Say (T 'inst.warn' @{ msg = $msg }) }
        }
    }
    if ($PostInstall) {
        Say (T 'inst.post')
        $r = Run-Native $vpy @('-u', (Join-Path $Prog $PostInstall), $Prog)
        $r.out | ForEach-Object { Write-Host ('      ' + $_) }
        if ($r.rc -ne 0) { throw (T 'inst.post_fail' @{ file = $PostInstall }) }
    }

    # --- 5) accesos directos, "Aplicaciones instaladas", desinstalador y comprobacion -------------------------------
    Step 5 (T 'inst.step.finish')
    $icoPath = Join-Path $Prog 'icon.ico'
    $hasIcoFile = Test-Path $icoPath
    $target = if ($Gui) { $vpyw } else { $vpy }
    $dirs = @([Environment]::GetFolderPath('Programs'))
    if ($Desktop) { $dirs += [Environment]::GetFolderPath('Desktop') }
    $sh = New-Object -ComObject WScript.Shell
    foreach ($dir in $dirs) {
        $s = $sh.CreateShortcut((Join-Path $dir ($LinkName + '.lnk')))
        $s.TargetPath = $target
        $s.Arguments = '"' + $Entry + '"'
        $s.WorkingDirectory = $Prog
        $s.Description = $Description
        if ($hasIcoFile) { $s.IconLocation = $icoPath + ',0' }
        $s.Save()
    }

    # tipos de archivo: el programa aparece en "Abrir con" (con su nombre e icono) y, si ningun otro
    # programa abre ese tipo, queda como el de siempre (doble clic). Si ya hay otro elegido, Windows no
    # deja cambiarlo por su cuenta: se explica al final como hacerlo.
    $needChoice = @()
    foreach ($a in $Assoc) {
        try {
            $pk = 'HKCU:\Software\Classes\' + $a.progid
            New-Item -Path ($pk + '\shell\open\command') -Force | Out-Null
            Set-ItemProperty -Path $pk -Name '(default)' -Value $a.desc
            Set-ItemProperty -Path ($pk + '\shell\open') -Name 'FriendlyAppName' -Value $AppName
            Set-ItemProperty -Path ($pk + '\shell\open\command') -Name '(default)' -Value ('"' + $target + '" "' + (Join-Path $Prog $Entry) + '" "%1"')
            if ($hasIcoFile) {
                New-Item -Path ($pk + '\DefaultIcon') -Force | Out-Null
                Set-ItemProperty -Path ($pk + '\DefaultIcon') -Name '(default)' -Value ($icoPath + ',0')
            }
            foreach ($e in $a.exts) {
                $ek = 'HKCU:\Software\Classes\' + $e
                New-Item -Path ($ek + '\OpenWithProgids') -Force | Out-Null
                New-ItemProperty -Path ($ek + '\OpenWithProgids') -Name $a.progid -Value ([byte[]]@()) -PropertyType None -Force | Out-Null
                $cur = $null
                try { $cur = (Get-Item -LiteralPath ('Registry::HKEY_CLASSES_ROOT\' + $e) -ErrorAction Stop).GetValue('') } catch { }
                $uc = $null
                try { $uc = (Get-ItemProperty -LiteralPath ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $e + '\UserChoice') -ErrorAction Stop).ProgId } catch { }
                if ((-not $cur -or $cur -eq $a.progid) -and (-not $uc -or $uc -eq $a.progid)) {
                    Set-ItemProperty -Path $ek -Name '(default)' -Value $a.progid
                } elseif ($uc -ne $a.progid) {
                    $needChoice += $e
                }
            }
        } catch { Say (T 'inst.assoc_fail' @{ exts = ($a.exts -join ', '); error = $_.Exception.Message }) }
    }
    if ($Assoc.Count -gt 0) {
        try {
            $sig = '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, int f, IntPtr a, IntPtr b);'
            (Add-Type -MemberDefinition $sig -Name ShN -Namespace Pyi -PassThru)::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
        } catch { }
        Say (T 'inst.assoc' @{ exts = ((@($Assoc | ForEach-Object { $_.exts }) | ForEach-Object { $_ }) -join ', ') })
    }

    # datos de la instalacion, por si el programa los necesita (actualizarse, saber de donde vino...)
    $info = [ordered]@{ id = $AppId; name = $AppName; version = $version; base_url = $Base; python = $py; venv = $venv; program_dir = $Prog; data_dir = $Root; installer = 'py-installer ' + $PyiVersion; lang = $Lang; installed_at = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText((Join-Path $Prog 'install_info.json'), ($info | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    # idioma del programa (lang-kit): el de este instalador, salvo que ya hubiera uno elegido (reinstalar no lo cambia)
    $langFile = Join-Path $Prog 'lang.json'
    if (-not (Test-Path $langFile)) { [IO.File]::WriteAllText($langFile, ('{"lang": "' + $Lang + '"}'), (New-Object Text.UTF8Encoding $false)) }

    # desinstalador (se guarda en $Root, no en $Prog: tiene que seguir ahi aunque se borren los datos)
    $un = @'
# uso: uninstall.ps1 [-Si] [-BorrarDatos]   (-Si: sin preguntar; sin -BorrarDatos se conservan tus datos)
param([switch]$Si, [switch]$BorrarDatos)
Add-Type -AssemblyName System.Windows.Forms
$name = '__NAME__'
$keep = @(__KEEP__)
$d = if ($BorrarDatos -or $keep.Count -eq 0) { 'Yes' } else { 'No' }
if (-not $Si) {
    $r = [Windows.Forms.MessageBox]::Show('__T_ASK__', $name, 'YesNo', 'Question')
    if ($r -ne 'Yes') { exit 0 }
    if ($keep.Count -gt 0 -and -not $BorrarDatos) { $d = [Windows.Forms.MessageBox]::Show('__T_ASK_DATA__', $name, 'YesNo', 'Question') }
}
try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.Name -like 'python*' -and $_.CommandLine -like '__PROCPAT__' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch { }
Start-Sleep -Milliseconds 800
foreach ($k in @('Programs', 'Desktop')) { try { Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath($k)) '__LINK__.lnk') -Force -ErrorAction SilentlyContinue } catch { } }
if (Test-Path '__PROG__') {
    if ($d -eq 'Yes') {
        Remove-Item -LiteralPath '__PROG__' -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath '__PROG__' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $keep } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Remove-Item -Path '__REGKEY__' -Recurse -Force -ErrorAction SilentlyContinue
__ASSOC_UNDO__
Start-Process -WindowStyle Hidden -FilePath cmd.exe -ArgumentList '/c ping -n 4 127.0.0.1 >nul & rmdir /s /q "__ROOT__"'
if ($Si) { Write-Host '__T_DONE__' } else { [void][Windows.Forms.MessageBox]::Show('__T_DONE__', $name, 'OK', 'Information') }
'@
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $procPat = '*' + [Management.Automation.WildcardPattern]::Escape($Prog) + '*' + [Management.Automation.WildcardPattern]::Escape($Entry) + '*'
    $keepList = (@($Keep) | ForEach-Object { & $q $_ }) -join ', '
    $sq = { param($s) ([string]$s).Replace("'", "''") }
    $undo = @()
    foreach ($a in $Assoc) {
        $p = & $sq $a.progid
        $undo += "Remove-Item -LiteralPath 'HKCU:\Software\Classes\$p' -Recurse -Force -ErrorAction SilentlyContinue"
        foreach ($e in $a.exts) {
            $k = 'HKCU:\Software\Classes\' + (& $sq $e)
            $undo += "Remove-ItemProperty -LiteralPath '$k\OpenWithProgids' -Name '$p' -ErrorAction SilentlyContinue"
            # el valor predeterminado se borra con .NET (Remove-ItemProperty '(default)' no lo quita en PowerShell 5.1)
            $sub = 'Software\Classes\' + (& $sq $e)
            $undo += "try { `$rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('$sub', `$true); if (`$rk) { if (`$rk.GetValue('') -eq '$p') { `$rk.DeleteValue('', `$false) }; `$rk.Close() } } catch { }"
        }
    }
    $un = $un.Replace('__ASSOC_UNDO__', ($undo -join "`r`n"))
    $un = $un.Replace('__T_ASK_DATA__', (& $sq (T 'uninst.ask_data'))).Replace('__T_ASK__', (& $sq (T 'uninst.ask' @{ app = $AppName }))).Replace('__T_DONE__', (& $sq (T 'uninst.done' @{ app = $AppName })))
    $un = $un.Replace('__NAME__', (& $sq $AppName)).Replace('__KEEP__', $keepList).Replace('__PROCPAT__', (& $sq $procPat)).Replace('__LINK__', (& $sq $LinkName)).Replace('__PROG__', (& $sq $Prog)).Replace('__REGKEY__', (& $sq $RegKey)).Replace('__ROOT__', $Root)
    [IO.File]::WriteAllText((Join-Path $Root 'uninstall.ps1'), $un, (New-Object Text.UTF8Encoding $true))

    New-Item -Path $RegKey -Force | Out-Null
    $vals = @{
        DisplayName     = $AppName
        DisplayVersion  = $version
        Publisher       = $Publisher
        InstallLocation = $Prog
        UninstallString = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Root 'uninstall.ps1') + '"')
        URLInfoAbout    = $Base
    }
    if ($hasIcoFile) { $vals['DisplayIcon'] = $icoPath }
    foreach ($k in $vals.Keys) { New-ItemProperty -Path $RegKey -Name $k -Value $vals[$k] -PropertyType String -Force | Out-Null }
    New-ItemProperty -Path $RegKey -Name NoModify -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $RegKey -Name NoRepair -Value 1 -PropertyType DWord -Force | Out-Null

    Remove-Item -Recurse -Force $Stage -ErrorAction SilentlyContinue

    # comprobacion final de verdad: ¿cargan las librerias que usa el programa?
    if ($CheckCode) {
        Say (T 'inst.checking')
        foreach ($k in $CheckEnv.Keys) { Set-Item -Path ('Env:' + $k) -Value $CheckEnv[$k] }
        $r = Run-Native $vpy @('-c', ($CheckCode + "`nprint('PYI_OK')"))
        foreach ($k in $CheckEnv.Keys) { Remove-Item -Path ('Env:' + $k) -ErrorAction SilentlyContinue }
        $smoke = $r.out -join "`n"
        if ($r.rc -ne 0 -or $smoke -notmatch 'PYI_OK') {
            Write-Host $smoke -ForegroundColor Yellow
            $hint = ''
            if ($smoke -match 'DLL load failed') { $hint = "`n`n" + (T 'inst.hint_vc' @{ app = $AppName }) }
            if ($smoke -match 'init\.tcl|TclError|_tkinter') { $hint += "`n`n" + (T 'inst.hint_tk' @{ dir = $venv }) }
            try { Stop-Transcript | Out-Null } catch { }
            Show-Box ((T 'inst.libs_broken' @{ app = $AppName }) + "`n`n" + (Tail $r 6) + $hint + "`n`n" + (T 'inst.log_at' @{ path = $LogFile })) 'Warning'
            exit 2
        }
        Say (T 'inst.libs_ok')
    }

    Write-Host ''
    Write-Host ('  ' + (T 'inst.ready' @{ app = $AppName })) -ForegroundColor Green
    if ($Desktop) { Write-Host ('  ' + (T 'inst.find_start_desktop')) } else { Write-Host ('  ' + (T 'inst.find_start')) }
    if ($needChoice.Count -gt 0) {
        Write-Host ('  ' + (T 'inst.choose_default' @{ exts = ($needChoice -join ', '); app = $AppName })) -ForegroundColor Yellow
    }
    if (-not (EnvOpt 'NO_LAUNCH')) {
        Write-Host ('  ' + (T 'inst.opening'))
        Start-Process -FilePath $target -ArgumentList ('"' + $Entry + '"') -WorkingDirectory $Prog
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}
catch {
    Write-Host ''
    Write-Host ('  ' + (T 'inst.error' @{ msg = $_.Exception.Message })) -ForegroundColor Red
    Write-Host ('  ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
    Show-Box ((T 'inst.failed') + "`n`n" + $_.Exception.Message + "`n`n" + (T 'inst.failed_retry') + "`n`n" + (T 'inst.log_at' @{ path = $LogFile })) 'Error'
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
