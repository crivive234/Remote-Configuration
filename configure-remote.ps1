<#
.SYNOPSIS
    Abre una sesión remota interactiva (Enter-PSSession) en un equipo a partir de su IP,
    con verificación de identidad opcional y sin dejar cambios permanentes en TrustedHosts.

.DESCRIPTION
    1. Valida la IP (IPv4 estricta: sin ceros a la izquierda ni direcciones especiales).
    2. Comprueba conectividad (ping) y, si se indica -MacAddress, verifica que la MAC
       asociada a esa IP coincida con la esperada (p. ej. la del lease DHCP) ANTES de
       enviar cualquier credencial.
    3. Solicita dominio, usuario y contraseña por pantalla (nada queda guardado en el script).
    4. (Opcional) Inicia WinRM en el equipo remoto usando esas MISMAS credenciales
       (CIM sobre DCOM), no la identidad de Windows de quien ejecuta el script.
    5. Agrega la IP a TrustedHosts solo mientras se establece la conexión y la retira
       justo después (no se toca el comodín "*" ni las demás entradas).
    6. Abre la sesión y, si se indica -ExpectedHostName, comprueba que el equipo remoto
       sea el esperado; si no coincide, cierra la sesión y sale.

    LIMITACIONES CONOCIDAS
    - Conectar por IP implica NTLM sin autenticación del servidor. La comprobación de MAC
      y de nombre reduce el riesgo de conectarse al equipo equivocado (lease cambiado),
      pero no sustituye a Kerberos (conexión por FQDN) ni a HTTPS con certificado.
    - La comprobación de MAC solo funciona si el equipo está en la misma subred.
    - Usa una cuenta con los permisos mínimos necesarios, no tu cuenta de administrador
      principal.

.PARAMETER IP
    IPv4 del equipo remoto. Si no se indica, el script la solicita por pantalla.

.PARAMETER Domain
    Dominio del usuario. Si se omite, se solicita por pantalla (se sugiere el dominio del
    equipo local si existe). Se ignora si el usuario se indica como 'DOMINIO\usuario'
    o 'usuario@dominio'.

.PARAMETER UserName
    Usuario sin dominio. Si se omite, se solicita por pantalla.

.PARAMETER Credential
    Objeto PSCredential ya creado. Si se omite, el script pide dominio, usuario y contraseña.

.PARAMETER MacAddress
    MAC esperada del equipo (formatos AA-BB-CC-DD-EE-FF, AA:BB:CC:DD:EE:FF o AABBCCDDEEFF).
    Si se indica y no se puede verificar o no coincide, el script se detiene.

.PARAMETER ExpectedHostName
    Nombre de equipo esperado (por ejemplo el del lease DHCP). Se compara con el nombre
    real del remoto una vez abierta la sesión.

.PARAMETER SkipServiceSetup
    Omite el inicio del servicio WinRM en el remoto (útil si ya está activo o si la cuenta
    no es administradora del equipo remoto).

.PARAMETER EnableAutoStart
    Además de iniciar WinRM, lo deja en inicio automático en el remoto. Por defecto NO se
    cambia el tipo de inicio, para no dejar modificaciones permanentes.

.PARAMETER Force
    No pide confirmación antes de agregar la IP temporalmente a TrustedHosts.

.EXAMPLE
    .\configure-remote.ps1

.EXAMPLE
    .\configure-remote.ps1 -IP 192.0.2.10 -MacAddress AA-BB-CC-DD-EE-FF -ExpectedHostName PC-EJEMPLO

.EXAMPLE
    .\configure-remote.ps1 -IP 192.0.2.10 -SkipServiceSetup
#>
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$IP,

    [string]$Domain,

    [string]$UserName,

    [System.Management.Automation.PSCredential]$Credential,

    [string]$MacAddress,

    [string]$ExpectedHostName,

    [switch]$SkipServiceSetup,

    [switch]$EnableAutoStart,

    [switch]$Force
)

# ==========================================
# CONEXIÓN REMOTA INTERACTIVA
# ==========================================

# ------------------------------------------
# 1. Obtener y validar la IP (y la MAC esperada, si se indicó)
# ------------------------------------------
if ([string]::IsNullOrWhiteSpace($IP)) {
    $IP = Read-Host "Introduce la IP del equipo remoto"
}

if ([string]::IsNullOrWhiteSpace($IP)) {
    Write-Host "No se ha ingresado ninguna IP. Saliendo..." -ForegroundColor Red
    exit 1
}

$IP = $IP.Trim()

# Octeto 0-255 sin ceros a la izquierda; [0-9] evita dígitos Unicode y \z evita el salto de línea final
$Octet = '(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
$IPv4Pattern = '^' + $Octet + '(?:\.' + $Octet + '){3}\z'
$ParsedIP = $null

if ($IP -notmatch $IPv4Pattern -or -not [System.Net.IPAddress]::TryParse($IP, [ref]$ParsedIP)) {
    Write-Host "'$IP' no es una dirección IPv4 válida. Saliendo..." -ForegroundColor Red
    exit 1
}

$IpBytes = $ParsedIP.GetAddressBytes()
if (($IpBytes[0] -eq 0) -or ($IpBytes[0] -eq 127) -or ($IpBytes[0] -ge 224)) {
    Write-Host "'$IP' no es una dirección de equipo válida (reservada, loopback, multicast o broadcast). Saliendo..." -ForegroundColor Red
    exit 1
}

# Se usa siempre la forma normalizada, no el texto original
$IP = $ParsedIP.ToString()

$ExpectedMac = $null
if (-not [string]::IsNullOrWhiteSpace($MacAddress)) {
    $ExpectedMac = ($MacAddress -replace '[-:.\s]', '').ToUpperInvariant()
    if ($ExpectedMac -notmatch '^[0-9A-F]{12}\z') {
        Write-Host "'$MacAddress' no es una MAC válida. Usa el formato AA-BB-CC-DD-EE-FF. Saliendo..." -ForegroundColor Red
        exit 1
    }
}

# ------------------------------------------
# 2. Conectividad y verificación de MAC (antes de enviar credenciales)
# ------------------------------------------
if ($ExpectedMac) {
    # Se borra la entrada ARP previa para no confiar en una caché antigua (lease cambiado)
    Remove-NetNeighbor -IPAddress $IP -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
}

if (-not (Test-Connection -ComputerName $IP -Count 2 -Quiet)) {
    Write-Warning "El equipo $IP no responde a ping. Puede estar apagado o bloquear ICMP; se continúa de todos modos."
}

if ($ExpectedMac) {
    $SeenMacs = @(
        Get-NetNeighbor -IPAddress $IP -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.State -notin 'Unreachable', 'Incomplete', 'Permanent' -and $_.LinkLayerAddress } |
            ForEach-Object { ($_.LinkLayerAddress -replace '[-:.\s]', '').ToUpperInvariant() } |
            Where-Object { $_ -and $_ -ne '000000000000' } |
            Select-Object -Unique
    )

    if ($SeenMacs.Count -eq 0) {
        Write-Host "No se pudo obtener la MAC de $IP (¿otra subred o equipo apagado?). No se puede verificar la identidad; se cancela." -ForegroundColor Red
        Write-Host "Si no necesitas esta verificación, ejecuta el script sin -MacAddress." -ForegroundColor Yellow
        exit 1
    }

    if (@($SeenMacs | Where-Object { $_ -ne $ExpectedMac }).Count -gt 0) {
        Write-Host "La MAC de $IP ($($SeenMacs -join ', ')) NO coincide con la esperada ($ExpectedMac). El equipo no es el que se esperaba; se cancela antes de enviar credenciales." -ForegroundColor Red
        exit 1
    }

    Write-Host "MAC verificada para $IP ($ExpectedMac)." -ForegroundColor DarkGray
}

# ------------------------------------------
# 3. Credenciales de acceso (se piden, no se guardan)
# ------------------------------------------
if (-not $Credential) {
    if ([string]::IsNullOrWhiteSpace($Domain)) {
        $SuggestedDomain = $env:USERDNSDOMAIN
        if ($SuggestedDomain) {
            $DomainInput = Read-Host "Dominio [$SuggestedDomain]"
        }
        else {
            $DomainInput = Read-Host "Dominio"
        }

        if (-not [string]::IsNullOrWhiteSpace($DomainInput)) {
            $Domain = $DomainInput.Trim()
        }
        elseif ($SuggestedDomain) {
            $Domain = $SuggestedDomain
        }
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
        if ([string]::IsNullOrWhiteSpace($Domain)) {
            Write-Host "No se indicó el dominio. Saliendo..." -ForegroundColor Red
            exit 1
        }
        $FullUser = "$($Domain.Trim())\$UserName"
    }

    $SecurePassword = Read-Host "Contraseña de $FullUser" -AsSecureString

    if ($SecurePassword.Length -eq 0) {
        Write-Host "No se ingresó ninguna contraseña. Saliendo..." -ForegroundColor Red
        exit 1
    }

    $Credential = New-Object System.Management.Automation.PSCredential($FullUser, $SecurePassword)
}

# ------------------------------------------
# 4. Iniciar WinRM en el equipo remoto (con las credenciales del paso 3)
#    Usa CIM sobre DCOM (puerto 135 + puertos RPC dinámicos). Por defecto solo inicia
#    el servicio; el inicio automático es opcional (-EnableAutoStart).
# ------------------------------------------
if (-not $SkipServiceSetup) {
    Write-Host "Verificando e iniciando el servicio WinRM en $IP..." -ForegroundColor Yellow

    $CimSession = $null
    try {
        $CimOptions = New-CimSessionOption -Protocol Dcom
        $CimSession = New-CimSession -ComputerName $IP -Credential $Credential -SessionOption $CimOptions -OperationTimeoutSec 20 -ErrorAction Stop

        $Service = Get-CimInstance -CimSession $CimSession -ClassName Win32_Service -Filter "Name='WinRM'" -ErrorAction Stop

        if ($Service.State -ne 'Running') {
            $Result = Invoke-CimMethod -InputObject $Service -MethodName StartService -ErrorAction Stop
            # 0 = iniciado; 10 = el servicio ya estaba en ejecución
            if ($Result.ReturnValue -notin 0, 10) {
                Write-Warning "No se pudo iniciar WinRM (código $($Result.ReturnValue)). Se intentará conectar de todos modos."
            }
        }

        if ($EnableAutoStart -and $Service.StartMode -ne 'Auto') {
            $Result = Invoke-CimMethod -InputObject $Service -MethodName ChangeStartMode -Arguments @{ StartMode = 'Automatic' } -ErrorAction Stop
            if ($Result.ReturnValue -ne 0) {
                Write-Warning "No se pudo configurar WinRM en inicio automático (código $($Result.ReturnValue))."
            }
        }
    }
    catch {
        Write-Warning "No se pudo gestionar WinRM en $IP : $($_.Exception.Message). Revisa permisos y el puerto 135. Se intentará conectar de todos modos."
    }
    finally {
        if ($CimSession) { Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------
# 5. TrustedHosts (equipo local): entrada TEMPORAL
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
$AddedTrusted = $false

if ($TrustedList -contains '*') {
    Write-Warning "TrustedHosts contiene '*': este equipo no verifica la identidad de NINGÚN host remoto. No se modifica, pero conviene corregirlo."
}
elseif ($TrustedList -contains $IP) {
    Write-Host "La IP $IP ya estaba en TrustedHosts (no se modificará ni se retirará)." -ForegroundColor DarkGray
}
else {
    if (-not $Force) {
        $Answer = Read-Host "Se agregará $IP a TrustedHosts solo durante la conexión y se retirará después. ¿Continuar? [S/n]"
        if ($Answer -match '^\s*(n|no)\s*$') {
            Write-Host "Operación cancelada." -ForegroundColor Yellow
            exit 1
        }
    }

    Set-Item -Path $TrustedPath -Value ((@($TrustedList) + $IP) -join ',') -Force
    $AddedTrusted = $true
    Write-Host "IP $IP agregada temporalmente a TrustedHosts." -ForegroundColor DarkGray
}

# ------------------------------------------
# 6. Verificar WinRM y crear la sesión
# ------------------------------------------
$Session = $null

try {
    $Ready = $false
    $LastError = ''

    # El servicio puede tardar unos segundos en aceptar conexiones tras iniciarse
    for ($Attempt = 1; $Attempt -le 3 -and -not $Ready; $Attempt++) {
        try {
            $null = Test-WSMan -ComputerName $IP -ErrorAction Stop
            $Ready = $true
        }
        catch {
            $LastError = $_.Exception.Message
            if ($Attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }

    if (-not $Ready) {
        throw "WinRM no responde en $IP ($LastError). Revisa que el equipo esté encendido, que WinRM esté activo y que el puerto 5985 esté permitido."
    }

    Write-Host "Conectando al equipo $IP..." -ForegroundColor Cyan

    $SessionOptions = New-PSSessionOption -OpenTimeout 30000
    $Session = New-PSSession -ComputerName $IP -Credential $Credential -Authentication Negotiate -SessionOption $SessionOptions -ErrorAction Stop
}
catch {
    Write-Host "No se pudo abrir la sesión en ${IP}: $($_.Exception.Message)" -ForegroundColor Red
}

if (-not $Session) {
    # Si la sesión falló y habíamos agregado la IP, la limpiamos antes de salir
    if ($AddedTrusted) {
        try {
            $Remaining = @(
                (Get-Item -Path $TrustedPath -ErrorAction Stop).Value -split ',' |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { $_ -and $_ -ne $IP }
            )
            Set-Item -Path $TrustedPath -Value ($Remaining -join ',') -Force
            Write-Host "IP $IP retirada de TrustedHosts." -ForegroundColor DarkGray
        }
        catch {
            # Silencioso al salir por error previo
        }
    }
    exit 1
}

# ------------------------------------------
# 7. Verificar que el equipo remoto es el esperado
# ------------------------------------------
$RemoteName = $null
try {
    $RemoteName = Invoke-Command -Session $Session -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
}
catch {
    Write-Warning "No se pudo obtener el nombre del equipo remoto: $($_.Exception.Message)"
}

if (-not [string]::IsNullOrWhiteSpace($ExpectedHostName)) {
    $ExpectedName = ($ExpectedHostName.Trim() -split '\.')[0]

    if (-not $RemoteName -or $RemoteName -ne $ExpectedName) {
        Write-Host "El equipo en $IP se llama '$RemoteName' y se esperaba '$ExpectedName'. Se cierra la sesión." -ForegroundColor Red
        Write-Host "Nota: la autenticación NTLM con ese equipo ya se realizó; considera cambiar la contraseña de la cuenta usada si el equipo no es de confianza." -ForegroundColor Yellow
        Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
        exit 1
    }

    Write-Host "Equipo remoto verificado: $RemoteName" -ForegroundColor Green
}
elseif ($RemoteName) {
    Write-Host "Equipo remoto: $RemoteName" -ForegroundColor Cyan
}

# ------------------------------------------
# 8. Lanzar la sesión interactiva
#    Enter-PSSession debe ser lo último: al terminar el script quedas en el prompt remoto.
#    Al salir con Exit-PSSession la sesión sigue abierta; ciérrala con el comando indicado.
# ------------------------------------------
if ($AddedTrusted) {
    $Remaining = @(
        (Get-Item -Path $TrustedPath -ErrorAction Stop).Value -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -ne $IP }
    )
    Write-Host "ATENCIÓN: Para retirar la IP de TrustedHosts al terminar, copia y ejecuta localmente este comando:" -ForegroundColor Yellow
    Write-Host "Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value '$($Remaining -join ',')' -Force" -ForegroundColor Cyan
}

Write-Host "Al terminar: Exit-PSSession  y luego  Remove-PSSession -Id $($Session.Id)" -ForegroundColor DarkGray

Enter-PSSession -Session $Session -ErrorAction Stop