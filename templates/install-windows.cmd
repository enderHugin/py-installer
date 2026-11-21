:: install-windows.cmd
@echo off
rem Instalador para Windows generado por py-installer (no necesita administrador ni tener Python instalado).
rem Este archivo es un .cmd con un script de PowerShell dentro: lo extrae y lo ejecuta.
title __PYI_TITLE__ - instalador
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
                throw ('la descarga no termino en ' + $timeoutSec + 's (conexion muy lenta o atascada)')
            }
            Receive-Job -Job $job -ErrorAction Stop | Out-Null
            if ((Get-Item $dest -ErrorAction SilentlyContinue).Length -gt 0) { return }
            throw 'el archivo descargado esta vacio'
        } catch {
            $last = $_
        } finally {
            if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }
        Start-Sleep -Seconds (2 * $try)
    }
    throw ("No se pudo descargar " + $url + " (" + $last + "). Comprueba tu conexion a internet.")
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
    else { Write-Host ('  ' + $AppName + ' no parece estar instalado.') }
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}

try {
    Write-Host ''
    Write-Host '  ==============================' -ForegroundColor Yellow
    Write-Host ('        ' + $AppName)           -ForegroundColor Yellow
    Write-Host '  ==============================' -ForegroundColor Yellow
    Write-Host '  Se instala solo para tu usuario. No hace falta nada mas: ni Python ni permisos de administrador.'
    Write-Host '  La primera vez descarga Python y las librerias; puede tardar un par de minutos.'

    Say ('registro de esta instalacion: ' + $LogFile)
    Say ('Windows ' + [Environment]::OSVersion.Version + ' | PowerShell ' + $PSVersionTable.PSVersion + ' | procesador ' + $env:PROCESSOR_ARCHITECTURE + ' | usuario ' + $env:USERNAME)
    Say ('programa en ' + $Prog)
    if (-not [Environment]::Is64BitOperatingSystem) { throw ($AppName + ' necesita un Windows de 64 bits.') }
    New-Item -ItemType Directory -Force -Path $Root, $Bin, $Rt, $Stage, $Prog | Out-Null
    Stop-Running

    try {
        $drive = (Get-Item $Root).PSDrive.Name
        $free = [math]::Floor((Get-PSDrive -Name $drive).Free / 1MB)
        if ($free -lt 700) { Say ('aviso: solo unos ' + $free + ' MB libres en la unidad ' + $drive + ':. Para instalar en otra unidad: cierra esto, ejecuta "set ' + $EnvPrefix + '_INSTALL_DIR=D:\' + $Folder + '" en una ventana de comandos y luego el instalador desde ahi.') }
    } catch { }

    # --- 1) uv: una herramienta de un solo archivo que descarga y gestiona Python -----------------------------------
    Step 1 'Preparando el gestor de Python (uv)'
    $uv = Join-Path $Bin 'uv.exe'
    $uvOk = $false
    if (Test-Path $uv) { $r = Run-Native $uv @('--version'); $uvOk = ($r.rc -eq 0) }
    if ($uvOk) {
        Say 'ya estaba instalado'
    } else {
        $zip = Join-Path $Root 'uv.zip'
        # Siempre la de 64 bits Intel/AMD: en Windows ARM funciona emulada y evita librerias que aun no existen para ARM.
        Get-File 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip' $zip
        $tmp = Join-Path $Root 'uv-tmp'
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $found = Get-ChildItem -Path $tmp -Recurse -Filter 'uv.exe' | Select-Object -First 1
        if (-not $found) { throw 'El archivo descargado de uv no contiene uv.exe.' }
        Copy-Item $found.FullName $uv -Force
        Remove-Item -Recurse -Force $tmp, $zip
        Say 'listo'
    }

    # --- 2) Python propio (no toca el Python que tengas instalado) --------------------------------------------------
    Step 2 ('Preparando Python ' + $PyVer)
    $env:UV_CACHE_DIR = Join-Path $Root 'cache'
    $env:UV_PYTHON_BIN_DIR = Join-Path $Bin 'python'   # que uv no deje python.exe en ~\.local\bin
    $env:UV_PYTHON_PREFERENCE = 'only-managed'
    $env:UV_PYTHON_DOWNLOADS = 'automatic'
    $env:UV_NO_PROGRESS = '1'
    # uv no lee el proxy de Windows: si PowerShell llega a GitHub por uno, se lo pasamos.
    if (-not ($env:HTTPS_PROXY -or $env:https_proxy)) {
        try {
            $sp = [Net.WebRequest]::GetSystemWebProxy(); $tu = [Uri]'https://github.com'
            if (-not $sp.IsBypassed($tu)) { $pu = $sp.GetProxy($tu); if ($pu -and $pu.AbsoluteUri -ne $tu.AbsoluteUri) { $env:HTTPS_PROXY = $pu.AbsoluteUri; Say ('proxy del sistema: ' + $pu.AbsoluteUri) } }
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
        @{ n = 'carpeta nueva y certificados de Windows'; dir = (Join-Path $Root 'py2'); env = @{ UV_SYSTEM_CERTS = '1' } },
        @{ n = 'carpeta corta y conexion lenta'; dir = (Join-Path $env:LOCALAPPDATA ($AppId + '-py')); env = @{ UV_SYSTEM_CERTS = '1'; UV_HTTP_TIMEOUT = '300'; UV_CONCURRENT_DOWNLOADS = '1' } }
    )
    foreach ($t in $tries) {
        foreach ($k in $t.env.Keys) { Set-Item -Path ('Env:' + $k) -Value $t.env[$k] }
        if ($t -ne $tries[0]) { Say ('reintentando con ' + $t.n + '...') }
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
        Say 'uv no pudo bajar Python; probando una descarga directa...'
        try {
            $rel = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest'
            $rx = '^cpython-' + [regex]::Escape($PyVer) + '\.\d+\+\d+-x86_64-pc-windows-msvc-install_only(_stripped)?\.tar\.gz$'
            $as = @($rel.assets | Where-Object { $_.name -match $rx }) | Select-Object -First 1
            if (-not $as) { throw ('no hay Python ' + $PyVer + ' para Windows en la ultima version publicada') }
            $tgz = Join-Path $Root 'python.tar.gz'
            Get-File $as.browser_download_url $tgz 480
            $dest = Join-Path $Rt ('manual-' + $PyVer)
            if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            & tar.exe -xzf $tgz -C $dest
            if ($LASTEXITCODE -ne 0) { throw ('tar fallo (codigo ' + $LASTEXITCODE + ')') }
            Remove-Item $tgz -Force -ErrorAction SilentlyContinue
            $cand = Join-Path $dest 'python\python.exe'
            if (-not (Test-Path $cand)) { throw 'el archivo descargado no contiene python.exe' }
            $r = Run-Native $cand @('-c', 'import sys; print(sys.version)')
            if ($r.rc -ne 0) { throw 'el Python descargado no arranca' }
            $py = $cand
        } catch { $uvTail += ' | descarga directa: ' + $_.Exception.Message }
    }
    if (-not $py -or -not (Test-Path $py)) {
        throw ('No se pudo conseguir Python ' + $PyVer + '. Puede ser Windows Defender (acceso controlado a carpetas) u otro antivirus que borra archivos mientras se descomprimen, o un proxy o cortafuegos que bloquea GitHub. Prueba a pausar el antivirus unos minutos y vuelve a ejecutar el instalador. Ultimos mensajes: ' + $uvTail)
    }
    Say $py
    if ($CheckCode -match 'tkinter') {
        # comprobacion temprana: mejor saber aqui que el Python descargado trae Tcl/Tk roto que al abrir el programa
        $r = Run-Native $py @('-c', 'import tkinter; tkinter.Tcl()')
        if ($r.rc -ne 0) { throw ('El Python descargado no trae tkinter funcionando (Tcl/Tk). Vuelve a ejecutar el instalador; si sigue fallando, cuentalo en ' + $IssuesUrl) }
    }

    # --- 3) el programa --------------------------------------------------------------------------------------------
    Step 3 ('Descargando ' + $AppName)
    foreach ($f in $Files) { Get-File ($Dl + '/' + $f) (Join-Path $Stage $f) }
    Get-File ($Dl + '/VERSION') (Join-Path $Stage 'VERSION')
    if ($HasIco) { try { Get-File ($Dl + '/icon.ico') (Join-Path $Stage 'icon.ico') } catch { Say 'no se pudo bajar el icono (se sigue sin el)' } }
    if ($DataZip) {
        try {
            $dz = Join-Path $Stage $DataZip
            Get-File ($Dl + '/' + $DataZip) $dz
            Expand-Archive -LiteralPath $dz -DestinationPath (Join-Path $Stage 'data') -Force
            Remove-Item $dz -Force
        } catch { Say ('no se pudieron bajar los datos iniciales (se omiten): ' + $_.Exception.Message) }
    }
    $version = (Get-Content (Join-Path $Stage 'VERSION') -Raw).Trim()
    Say ('version ' + $version)

    # --- 4) entorno con sus librerias (la parte lenta) --------------------------------------------------------------
    Step 4 'Instalando el programa y sus librerias'
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
    $venv = Join-Path $Prog '.venv'
    $vpy  = Join-Path $venv 'Scripts\python.exe'
    $vpyw = Join-Path $venv 'Scripts\pythonw.exe'
    # un entorno a medias de un intento anterior (sin pythonw.exe, sin pip o con otro Python) se rehace solo
    $venvOk = $false
    if (Test-Path $vpyw) {
        $r = Run-Native $vpy @('-c', ("import pip, sys; assert '%d.%d' % sys.version_info[:2] == '" + $PyVer + "'"))
        if ($r.rc -eq 0) { $venvOk = $true } else { Say 'entorno anterior incompleto: se rehace' }
    }
    if (-not $venvOk -and (Test-Path $venv)) { Remove-Item -LiteralPath $venv -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $venvOk) {
        # --seed: que incluya pip, para que el programa pueda instalar extras por su cuenta si lo necesita
        $r = Run-Uv @('venv', '--seed', '--python', $py, $venv)
        if ($r.rc -ne 0 -or -not (Test-Path $vpyw)) { throw ('no se pudo crear el entorno de Python: ' + (Tail $r)) }
    } else {
        Say 'el entorno ya estaba'
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
        Say ('librerias: ' + ($Required -join ', '))
        $r = Install-Pkgs $Required
        if ($r.rc -ne 0) { throw ('fallo al instalar las librerias (' + ($Required -join ', ') + '): ' + (Tail $r)) }
    }
    foreach ($o in $Optional) {
        $r = Install-Pkgs @($o.pkg)
        if ($r.rc -ne 0) { Say ('no se pudo instalar ' + $o.pkg + ' (opcional; ' + $o.why + '): ' + (Tail $r 2)) }
    }
    foreach ($x in $Extras) {
        $dstDir = Join-Path $Prog $x.to
        $missing = @($x.extract | Where-Object { -not (Test-Path (Join-Path $dstDir $_)) })
        if ($missing.Count -eq 0) { Say ($x.label + ': ya estaba'); continue }
        Say ('descargando ' + $x.label + '...')
        $ext = if ($x.url -match '\.zip($|\?)') { '.zip' } else { '.tar.gz' }
        $arc = Join-Path $Root ('extra' + $ext)
        try {
            Get-File $x.url $arc 600
            $got = Expand-Picked $arc $x.extract $dstDir
            Remove-Item $arc -Force -ErrorAction SilentlyContinue
            if ($got.Count -lt $x.extract.Count) { throw ('faltan en el archivo descargado: ' + ((@($x.extract | Where-Object { $got -notcontains $_ })) -join ', ')) }
        } catch {
            $msg = $x.label + ': ' + $_.Exception.Message + '. Puedes bajarlo tu mismo de ' + $x.url + ' y copiar ' + ($x.extract -join ', ') + ' a "' + $dstDir + '"; luego vuelve a ejecutar el instalador.'
            if ($x.required) { throw $msg } else { Say ('aviso: ' + $msg) }
        }
    }
    if ($PostInstall) {
        Say 'paso propio del programa...'
        $r = Run-Native $vpy @('-u', (Join-Path $Prog $PostInstall), $Prog)
        $r.out | ForEach-Object { Write-Host ('      ' + $_) }
        if ($r.rc -ne 0) { throw ('el paso propio del programa (' + $PostInstall + ') fallo') }
    }

    # --- 5) accesos directos, "Aplicaciones instaladas", desinstalador y comprobacion -------------------------------
    Step 5 'Terminando: accesos directos y desinstalador'
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

    # datos de la instalacion, por si el programa los necesita (actualizarse, saber de donde vino...)
    $info = [ordered]@{ id = $AppId; name = $AppName; version = $version; base_url = $Base; python = $py; venv = $venv; program_dir = $Prog; data_dir = $Root; installer = 'py-installer ' + $PyiVersion; installed_at = (Get-Date).ToString('s') }
    [IO.File]::WriteAllText((Join-Path $Prog 'install_info.json'), ($info | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

    # desinstalador (se guarda en $Root, no en $Prog: tiene que seguir ahi aunque se borren los datos)
    $un = @'
# uso: uninstall.ps1 [-Si] [-BorrarDatos]   (-Si: sin preguntar; sin -BorrarDatos se conservan tus datos)
param([switch]$Si, [switch]$BorrarDatos)
Add-Type -AssemblyName System.Windows.Forms
$name = '__NAME__'
$keep = @(__KEEP__)
$d = if ($BorrarDatos -or $keep.Count -eq 0) { 'Yes' } else { 'No' }
if (-not $Si) {
    $r = [Windows.Forms.MessageBox]::Show("¿Desinstalar $name?", $name, 'YesNo', 'Question')
    if ($r -ne 'Yes') { exit 0 }
    if ($keep.Count -gt 0 -and -not $BorrarDatos) { $d = [Windows.Forms.MessageBox]::Show("¿Borrar tambien tus datos y ajustes?`n`nSi dices que no, se conservan por si vuelves a instalarlo.", $name, 'YesNo', 'Question') }
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
Start-Process -WindowStyle Hidden -FilePath cmd.exe -ArgumentList '/c ping -n 4 127.0.0.1 >nul & rmdir /s /q "__ROOT__"'
if ($Si) { Write-Host "$name se ha desinstalado." } else { [void][Windows.Forms.MessageBox]::Show("$name se ha desinstalado.", $name, 'OK', 'Information') }
'@
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $procPat = '*' + [Management.Automation.WildcardPattern]::Escape($Prog) + '*' + [Management.Automation.WildcardPattern]::Escape($Entry) + '*'
    $keepList = (@($Keep) | ForEach-Object { & $q $_ }) -join ', '
    $sq = { param($s) ([string]$s).Replace("'", "''") }
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
        Say 'comprobando que las librerias cargan...'
        foreach ($k in $CheckEnv.Keys) { Set-Item -Path ('Env:' + $k) -Value $CheckEnv[$k] }
        $r = Run-Native $vpy @('-c', ($CheckCode + "`nprint('PYI_OK')"))
        foreach ($k in $CheckEnv.Keys) { Remove-Item -Path ('Env:' + $k) -ErrorAction SilentlyContinue }
        $smoke = $r.out -join "`n"
        if ($r.rc -ne 0 -or $smoke -notmatch 'PYI_OK') {
            Write-Host $smoke -ForegroundColor Yellow
            $hint = ''
            if ($smoke -match 'DLL load failed') { $hint = "`n`nFalta el componente 'Microsoft Visual C++ Redistributable'. Instalalo desde https://aka.ms/vs/17/release/vc_redist.x64.exe y abre " + $AppName + " desde el menu Inicio." }
            if ($smoke -match 'init\.tcl|TclError|_tkinter') { $hint += "`n`nEsto suele ser el entorno de Python a medias. Vuelve a ejecutar el instalador (borra primero la carpeta '" + $venv + "' si sigue fallando)." }
            try { Stop-Transcript | Out-Null } catch { }
            Show-Box ($AppName + " se ha instalado, pero sus librerias no cargan en este equipo, asi que no se abrira todavia.`n`n" + (Tail $r 6) + $hint + "`n`nRegistro: " + $LogFile) 'Warning'
            exit 2
        }
        Say 'librerias correctas'
    }

    Write-Host ''
    Write-Host ('  Listo. ' + $AppName + ' esta instalado.') -ForegroundColor Green
    Write-Host '  Lo encuentras en el menu Inicio' -NoNewline; if ($Desktop) { Write-Host ' y en el escritorio.' } else { Write-Host '.' }
    if (-not (EnvOpt 'NO_LAUNCH')) {
        Write-Host '  Se abre ahora.'
        Start-Process -FilePath $target -ArgumentList ('"' + $Entry + '"') -WorkingDirectory $Prog
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 0
}
catch {
    Write-Host ''
    Write-Host ('  ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('  ' + $_.ScriptStackTrace) -ForegroundColor DarkGray
    Show-Box ("No se pudo completar la instalacion:`n`n" + $_.Exception.Message + "`n`nPuedes volver a ejecutar el instalador: continuara donde lo dejo.`n`nRegistro: " + $LogFile) 'Error'
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
