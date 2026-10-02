<#
.SYNOPSIS
    Abre una sesión remota interactiva (Enter-PSSession) en un equipo a partir de su IP.

.DESCRIPTION
    1. Valida la IP y comprueba conectividad básica.
    2. (Opcional) Deja WinRM en inicio automático y lo inicia en el equipo remoto con sc.exe.
    3. Agrega la IP a TrustedHosts local (comparación exacta, sin tocar el comodín "*").
    4. Solicita dominio, usuario y contraseña por pantalla (la contraseña no se muestra ni se guarda).
    5. Verifica que WinRM responda y abre la sesión interactiva.

.PARAMETER IP
    IPv4 del equipo remoto. Si no se indica, el script la solicita por pantalla.

.PARAMETER Domain
    Dominio del usuario. Por defecto 'ititpa.itic'. Al ejecutar el script se puede aceptar
    con Enter o escribir otro.

.PARAMETER UserName
    Usuario sin dominio (por ejemplo 'cristian.viasus'). Si se omite, se solicita por pantalla.
    También se acepta 'DOMINIO\usuario' o 'usuario@dominio'; en ese caso no se agrega el dominio.

.PARAMETER Credential
    Objeto PSCredential ya creado. Si se omite, el script pide dominio, usuario y contraseña.

.PARAMETER SkipServiceSetup
    Omite el paso de sc.exe (útil si WinRM ya está activo en el remoto o si el usuario
    que ejecuta el script no es administrador del equipo remoto).

.EXAMPLE
    .\configure-remote.ps1

.EXAMPLE
    .\configure-remote.ps1 -IP 10.158.131.20 -SkipServiceSetup
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$IP,

    [string]$Domain = 'ititpa.itic',

    [string]$UserName,

    [System.Management.Automation.PSCredential]$Credential,

    [switch]$SkipServiceSetup
)

# ==========================================
# CONEXIÓN REMOTA INTERACTIVA
# ==========================================

# ------------------------------------------
# 1. Obtener y validar la IP
# ------------------------------------------
if ([string]::IsNullOrWhiteSpace($IP)) {
    $IP = Read-Host "Introduce la IP del equipo remoto"
}

if ([string]::IsNullOrWhiteSpace($IP)) {
    Write-Host "No se ha ingresado ninguna IP. Saliendo..." -ForegroundColor Red
    exit 1
}

$IP = $IP.Trim()
$ParsedIP = $null

if ($IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [System.Net.IPAddress]::TryParse($IP, [ref]$ParsedIP)) {
    Write-Host "'$IP' no es una dirección IPv4 válida. Saliendo..." -ForegroundColor Red
    exit 1
}

# ------------------------------------------
# 2. Comprobar conectividad (solo aviso)
# ------------------------------------------
if (-not (Test-Connection -ComputerName $IP -Count 1 -Quiet)) {
    Write-Warning "El equipo $IP no responde a ping. Puede estar apagado o bloquear ICMP; se continúa de todos modos."
}

# ------------------------------------------
# 3. Configurar e iniciar WinRM en el equipo remoto
#    Nota: sc.exe usa la identidad de Windows de quien ejecuta el script,
#    no las credenciales del paso 5.
# ------------------------------------------
if (-not $SkipServiceSetup) {
    Write-Host "Verificando e iniciando el servicio WinRM en $IP..." -ForegroundColor Yellow

    $null = & sc.exe "\\$IP" config WinRM start= auto
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "No se pudo configurar WinRM en inicio automático (sc.exe código $LASTEXITCODE). Revisa permisos y puertos 135/445."
    }

    $null = & sc.exe "\\$IP" start WinRM
    # 0 = iniciado; 1056 = el servicio ya estaba en ejecución
    if ($LASTEXITCODE -notin 0, 1056) {
        Write-Warning "No se pudo iniciar WinRM (sc.exe código $LASTEXITCODE). Se intentará conectar de todos modos."
    }
}

# ------------------------------------------
# 4. Agregar la IP a TrustedHosts (equipo local)
# ------------------------------------------
$TrustedPath = 'WSMan:\localhost\Client\TrustedHosts'

try {
    if ((Get-Service -Name WinRM).Status -ne 'Running') {
        Start-Service -Name WinRM
    }
    $CurrentTrusted = (Get-Item -Path $TrustedPath -ErrorAction Stop).Value
}
catch {
    Write-Host "No se pudo leer la configuración local de WinRM: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Prueba ejecutando 'Enable-PSRemoting -Force' y vuelve a intentar." -ForegroundColor Yellow
    exit 1
}

$TrustedList = @($CurrentTrusted -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($TrustedList -contains '*') {
    Write-Host "TrustedHosts ya confía en todos los equipos ('*'). No se modifica." -ForegroundColor DarkYellow
}
elseif ($TrustedList -contains $IP) {
    Write-Host "La IP $IP ya está en TrustedHosts." -ForegroundColor DarkGray
}
else {
    $NewValue = (@($TrustedList) + $IP) -join ','
    Set-Item -Path $TrustedPath -Value $NewValue -Force
    Write-Host "IP $IP agregada a TrustedHosts." -ForegroundColor DarkGray
}

# ------------------------------------------
# 5. Credenciales de acceso (se piden, no se guardan)
# ------------------------------------------
if (-not $Credential) {
    $DomainInput = Read-Host "Dominio [$Domain]"
    if (-not [string]::IsNullOrWhiteSpace($DomainInput)) {
        $Domain = $DomainInput.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        $UserName = Read-Host "Usuario (sin dominio)"
    }

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        Write-Host "No se ingresó ningún usuario. Saliendo..." -ForegroundColor Red
        exit 1
    }

    $UserName = $UserName.Trim()

    # Si ya viene como DOMINIO\usuario o usuario@dominio, se respeta tal cual
    if ($UserName -match '[\\@]') {
        $FullUser = $UserName
    }
    else {
        $FullUser = "$Domain\$UserName"
    }

    $SecurePassword = Read-Host "Contraseña de $FullUser" -AsSecureString

    if ($SecurePassword.Length -eq 0) {
        Write-Host "No se ingresó ninguna contraseña. Saliendo..." -ForegroundColor Red
        exit 1
    }

    $Credential = New-Object System.Management.Automation.PSCredential($FullUser, $SecurePassword)
}

# ------------------------------------------
# 6. Verificar que WinRM responde en el remoto
# ------------------------------------------
try {
    $null = Test-WSMan -ComputerName $IP -ErrorAction Stop
}
catch {
    Write-Host "WinRM no responde en $IP : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Revisa que el equipo esté encendido, que WinRM esté activo y que el puerto 5985 esté permitido." -ForegroundColor Yellow
    exit 1
}

# ------------------------------------------
# 7. Lanzar la sesión interactiva
#    Enter-PSSession debe ser lo último: al terminar el script
#    quedas en el prompt remoto. Usa Exit-PSSession para salir.
# ------------------------------------------
Write-Host "Conectando al equipo $IP..." -ForegroundColor Cyan

try {
    Enter-PSSession -ComputerName $IP -Credential $Credential -ErrorAction Stop
}
catch {
    Write-Host "No se pudo abrir la sesión en $IP : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
