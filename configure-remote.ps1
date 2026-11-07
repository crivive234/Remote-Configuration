<#
.SYNOPSIS
    Abre sesiones remotas interactivas (una tras otra, en bucle) en equipos a partir de su IP,
    con verificación de identidad opcional y sin dejar cambios permanentes en TrustedHosts.

.DESCRIPTION
    El script trabaja en bucle: pide una IP, abre la sesión remota y, cuando sales de ella
    (con confirmación), vuelve a pedir otra IP. Para terminar el script se escribe 'salir'
    en el prompt de la IP (también con confirmación).

    Por cada equipo:
    1. Valida la IP (IPv4 estricta: sin ceros a la izquierda ni direcciones especiales).
    2. Comprueba conectividad (ping) y, si se indica -MacAddress, verifica que la MAC
       asociada a esa IP coincida con la esperada (p. ej. la del lease DHCP) ANTES de
       enviar cualquier credencial.
    3. Solicita dominio, usuario y contraseña por pantalla (solo la primera vez; luego se
       reutilizan en memoria hasta que se escriba 'c' en el prompt de la IP o termine el
       script). Nada queda guardado en el script ni en disco.
    4. (Opcional) Inicia WinRM en el equipo remoto usando esas MISMAS credenciales
       (CIM sobre DCOM), no la identidad de Windows de quien ejecuta el script.
    5. Agrega la IP a TrustedHosts solo mientras dura la conexión y la retira
       automáticamente al salir (no se toca el comodín "*" ni las demás entradas).
    6. Abre la sesión y, si se indica -ExpectedHostName, comprueba que el equipo remoto
       sea el esperado; si no coincide, cierra la sesión y vuelve al inicio.
    7. Muestra un prompt remoto propio ("[EQUIPO] PS ruta>"): cada línea que escribes se
       ejecuta en el equipo remoto. Al escribir 'exit' o 'salir' se pide confirmación; si
       confirmas, se cierra la sesión, se retira la IP de TrustedHosts y se vuelve a pedir
       una IP.

    POR QUÉ NO SE USA Enter-PSSession
    Enter-PSSession no devuelve el control al script cuando terminas la sesión remota
    (el script ya habría terminado), por lo que no se podría volver al inicio ni pedir
    confirmación. Por eso el script incluye su propio prompt remoto. Diferencias: un comando
    por línea, sin autocompletado con Tab y sin programas que pidan entrada interactiva.

    LIMITACIONES CONOCIDAS
    - Conectar por IP implica NTLM sin autenticación del servidor. La comprobación de MAC
      y de nombre reduce el riesgo de conectarse al equipo equivocado (lease cambiado),
      pero no sustituye a Kerberos (conexión por FQDN) ni a HTTPS con certificado.
    - La comprobación de MAC solo funciona si el equipo está en la misma subred.
    - Usa una cuenta con los permisos mínimos necesarios, no tu cuenta de administrador
      principal.

.PARAMETER IP
    IPv4 del equipo remoto para la primera conexión. Si no se indica, el script la solicita
    por pantalla. Después de cada sesión el script vuelve a pedir una IP.

.PARAMETER Domain
    Dominio del usuario. Si se omite, se solicita por pantalla (se sugiere el dominio del
    equipo local si existe). Se ignora si el usuario se indica como 'DOMINIO\usuario'
    o 'usuario@dominio'.

.PARAMETER UserName
    Usuario sin dominio. Si se omite, se solicita por pantalla.

.PARAMETER Credential
    Objeto PSCredential ya creado. Si se omite, el script pide dominio, usuario y contraseña.

.PARAMETER MacAddress
    MAC esperada del equipo de la PRIMERA conexión (formatos AA-BB-CC-DD-EE-FF,
    AA:BB:CC:DD:EE:FF o AABBCCDDEEFF). Si se indica y no se puede verificar o no coincide,
    esa conexión se cancela. Las siguientes IP que escribas no usan esta verificación.

.PARAMETER ExpectedHostName
    Nombre de equipo esperado en la PRIMERA conexión (por ejemplo el del lease DHCP). Se
    compara con el nombre real del remoto una vez abierta la sesión.

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
# CONEXIÓN REMOTA INTERACTIVA (EN BUCLE)
# ==========================================

$TrustedPath = 'WSMan:\localhost\Client\TrustedHosts'

# Credenciales en memoria: se piden una vez y se reutilizan para las siguientes IP.
# Escribir 'c' en el prompt de la IP las descarta para volver a pedirlas.
$script:StoredCredential = $Credential
$script:StoredDomain     = $Domain
$script:StoredUserName   = $UserName

# ==========================================
# FUNCIONES AUXILIARES
# ==========================================

function Read-Confirmation {
    param(
        [Parameter(Mandatory)][string]$Message,
        [bool]$DefaultYes = $true
    )

    $Hint = if ($DefaultYes) { '[S/n]' } else { '[s/N]' }

    while ($true) {
        $Answer = Read-Host "$Message $Hint"
        $Answer = "$Answer".Trim()

        if ($Answer -eq '') { return $DefaultYes }
        if ($Answer -match '^(s|si|sí|y|yes)$') { return $true }
        if ($Answer -match '^(n|no)$') { return $false }

        Write-Host "Responde S o N." -ForegroundColor Yellow
    }
}

function ConvertTo-ValidIPv4 {
    param([string]$Text)

    $Text = "$Text".Trim()

    # Octeto 0-255 sin ceros a la izquierda; [0-9] evita dígitos Unicode y \z evita el salto de línea final
    $Octet = '(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    $IPv4Pattern = '^' + $Octet + '(?:\.' + $Octet + '){3}\z'
    $ParsedIP = $null

    if ($Text -notmatch $IPv4Pattern -or -not [System.Net.IPAddress]::TryParse($Text, [ref]$ParsedIP)) {
        Write-Host "'$Text' no es una dirección IPv4 válida." -ForegroundColor Red
        return $null
    }

    $IpBytes = $ParsedIP.GetAddressBytes()
    if (($IpBytes[0] -eq 0) -or ($IpBytes[0] -eq 127) -or ($IpBytes[0] -ge 224)) {
        Write-Host "'$Text' no es una dirección de equipo válida (reservada, loopback, multicast o broadcast)." -ForegroundColor Red
        return $null
    }

    # Se usa siempre la forma normalizada, no el texto original
    return $ParsedIP.ToString()
}

function ConvertTo-NormalizedMac {
    param([string]$Text)

    $Mac = ("$Text" -replace '[-:.\s]', '').ToUpperInvariant()
    if ($Mac -notmatch '^[0-9A-F]{12}\z') {
        Write-Host "'$Text' no es una MAC válida. Usa el formato AA-BB-CC-DD-EE-FF." -ForegroundColor Red
        return $null
    }

    return $Mac
}

# Conectividad y verificación de MAC (antes de enviar credenciales). Devuelve $true si se puede continuar.
function Test-HostIdentity {
    param(
        [Parameter(Mandatory)][string]$IP,
        [string]$ExpectedMac
    )

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
            return $false
        }

        if (@($SeenMacs | Where-Object { $_ -ne $ExpectedMac }).Count -gt 0) {
            Write-Host "La MAC de $IP ($($SeenMacs -join ', ')) NO coincide con la esperada ($ExpectedMac). El equipo no es el que se esperaba; se cancela antes de enviar credenciales." -ForegroundColor Red
            return $false
        }

        Write-Host "MAC verificada para $IP ($ExpectedMac)." -ForegroundColor DarkGray
    }

    return $true
}

# Pide dominio, usuario y contraseña. Devuelve un PSCredential o $null si se cancela.
function Read-RemoteCredential {
    $DomainName = $script:StoredDomain
    $User = $script:StoredUserName

    if ([string]::IsNullOrWhiteSpace($DomainName)) {
        $SuggestedDomain = $env:USERDNSDOMAIN
        if ($SuggestedDomain) {
            $DomainInput = Read-Host "Dominio [$SuggestedDomain]"
        }
        else {
            $DomainInput = Read-Host "Dominio"
        }

        if (-not [string]::IsNullOrWhiteSpace($DomainInput)) {
            $DomainName = $DomainInput.Trim()
        }
        elseif ($SuggestedDomain) {
            $DomainName = $SuggestedDomain
        }
    }

    if ([string]::IsNullOrWhiteSpace($User)) {
        $User = Read-Host "Usuario (sin dominio)"
    }

    if ([string]::IsNullOrWhiteSpace($User)) {
        Write-Host "No se ingresó ningún usuario." -ForegroundColor Red
        return $null
    }

    $User = $User.Trim()

    # Si ya viene como DOMINIO\usuario o usuario@dominio, se respeta tal cual
    if ($User -match '[\\@]') {
        $FullUser = $User
    }
    else {
        if ([string]::IsNullOrWhiteSpace($DomainName)) {
            Write-Host "No se indicó el dominio." -ForegroundColor Red
            return $null
        }
        $FullUser = "$($DomainName.Trim())\$User"
    }

    $SecurePassword = Read-Host "Contraseña de $FullUser" -AsSecureString

    if ($SecurePassword.Length -eq 0) {
        Write-Host "No se ingresó ninguna contraseña." -ForegroundColor Red
        return $null
    }

    return (New-Object System.Management.Automation.PSCredential($FullUser, $SecurePassword))
}

# Inicia WinRM en el equipo remoto (con las credenciales indicadas).
# Usa CIM sobre DCOM (puerto 135 + puertos RPC dinámicos). Por defecto solo inicia
# el servicio; el inicio automático es opcional (-EnableAutoStart).
function Start-RemoteWinRM {
    param(
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)]$Cred
    )

    Write-Host "Verificando e iniciando el servicio WinRM en $IP..." -ForegroundColor Yellow

    $CimSession = $null
    try {
        $CimOptions = New-CimSessionOption -Protocol Dcom
        $CimSession = New-CimSession -ComputerName $IP -Credential $Cred -SessionOption $CimOptions -OperationTimeoutSec 20 -ErrorAction Stop

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

# Retira la IP de TrustedHosts sin tocar el resto de entradas.
function Remove-TrustedHostEntry {
    param([Parameter(Mandatory)][string]$IP)

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
        Write-Warning "No se pudo retirar $IP de TrustedHosts: $($_.Exception.Message)"
        Write-Host "Revísalo manualmente con: Get-Item WSMan:\localhost\Client\TrustedHosts" -ForegroundColor Yellow
    }
}

# Prompt remoto propio: cada línea se ejecuta en el equipo remoto. Termina al confirmar la salida
# o si la sesión deja de estar activa.
function Enter-RemotePrompt {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$IP,
        [string]$RemoteName
    )

    $Label = if ($RemoteName) { $RemoteName } else { $IP }
    $Display = if ($RemoteName) { "$RemoteName ($IP)" } else { $IP }

    Write-Host ''
    Write-Host "Sesión remota abierta en $Display. Escribe 'exit' o 'salir' para cerrarla (se pedirá confirmación)." -ForegroundColor Green
    Write-Host "Un comando por línea; sin autocompletado con Tab ni programas interactivos." -ForegroundColor DarkGray

    while ($true) {
        $RemotePath = '?'
        try {
            $RemotePath = Invoke-Command -Session $Session -ScriptBlock { (Get-Location).Path } -ErrorAction Stop
        }
        catch {
            # Se detecta justo debajo por el estado de la sesión
        }

        if ($Session.State -ne 'Opened') {
            Write-Warning "La sesión remota con $Display ya no está activa (estado: $($Session.State))."
            break
        }

        Write-Host "[$Label] PS ${RemotePath}> " -NoNewline -ForegroundColor Cyan
        $Line = Read-Host
        $Line = "$Line".Trim()

        if ($Line -eq '') { continue }

        if ($Line -match '^(exit|salir|quit|exit-pssession)$') {
            if (Read-Confirmation "¿Cerrar la sesión con $Display?") { break }
            continue
        }

        if ($Line -match '^(cls|clear|clear-host)$') {
            Clear-Host
            continue
        }

        try {
            Invoke-Command -Session $Session -ScriptBlock { param($Cmd) Invoke-Expression $Cmd } -ArgumentList $Line -HideComputerName
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
    }
}

# Todo el proceso para UN equipo: identidad, credenciales, WinRM, TrustedHosts, sesión y prompt remoto.
# Al terminar (por cualquier camino) cierra la sesión y retira la IP de TrustedHosts.
function Invoke-RemoteConnection {
    param(
        [Parameter(Mandatory)][string]$IP,
        [string]$ExpectedMac,
        [string]$ExpectedHostName
    )

    # ------------------------------------------
    # 2. Conectividad y verificación de MAC (antes de enviar credenciales)
    # ------------------------------------------
    if (-not (Test-HostIdentity -IP $IP -ExpectedMac $ExpectedMac)) { return }

    # ------------------------------------------
    # 3. Credenciales de acceso (se piden una vez, solo en memoria)
    # ------------------------------------------
    if (-not $script:StoredCredential) {
        $script:StoredCredential = Read-RemoteCredential
        if (-not $script:StoredCredential) { return }
    }
    $Cred = $script:StoredCredential

    # ------------------------------------------
    # 4. Iniciar WinRM en el equipo remoto (con las credenciales del paso 3)
    # ------------------------------------------
    if (-not $SkipServiceSetup) {
        Start-RemoteWinRM -IP $IP -Cred $Cred
    }

    $AddedTrusted = $false
    $Session = $null

    try {
        # ------------------------------------------
        # 5. TrustedHosts (equipo local): entrada TEMPORAL
        # ------------------------------------------
        try {
            if ((Get-Service -Name WinRM).Status -ne 'Running') {
                Start-Service -Name WinRM
            }
            $CurrentTrusted = (Get-Item -Path $TrustedPath -ErrorAction Stop).Value
        }
        catch {
            Write-Host "No se pudo leer la configuración local de WinRM: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Prueba ejecutando 'Enable-PSRemoting -Force' y vuelve a intentar." -ForegroundColor Yellow
            return
        }

        $TrustedList = @($CurrentTrusted -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        if ($TrustedList -contains '*') {
            Write-Warning "TrustedHosts contiene '*': este equipo no verifica la identidad de NINGÚN host remoto. No se modifica, pero conviene corregirlo."
        }
        elseif ($TrustedList -contains $IP) {
            Write-Host "La IP $IP ya estaba en TrustedHosts (no se modificará ni se retirará)." -ForegroundColor DarkGray
        }
        else {
            if (-not $Force) {
                if (-not (Read-Confirmation "Se agregará $IP a TrustedHosts solo durante la conexión y se retirará al salir. ¿Continuar?")) {
                    Write-Host "Operación cancelada." -ForegroundColor Yellow
                    return
                }
            }

            Set-Item -Path $TrustedPath -Value ((@($TrustedList) + $IP) -join ',') -Force
            $AddedTrusted = $true
            Write-Host "IP $IP agregada temporalmente a TrustedHosts." -ForegroundColor DarkGray
        }

        # ------------------------------------------
        # 6. Verificar WinRM y crear la sesión
        # ------------------------------------------
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
            $Session = New-PSSession -ComputerName $IP -Credential $Cred -Authentication Negotiate -SessionOption $SessionOptions -ErrorAction Stop
        }
        catch {
            Write-Host "No se pudo abrir la sesión en ${IP}: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Si el usuario o la contraseña son incorrectos, escribe 'c' en el prompt de la IP para volver a ingresarlos." -ForegroundColor Yellow
            return
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
                return
            }

            Write-Host "Equipo remoto verificado: $RemoteName" -ForegroundColor Green
        }
        elseif ($RemoteName) {
            Write-Host "Equipo remoto: $RemoteName" -ForegroundColor Cyan
        }

        # ------------------------------------------
        # 8. Prompt remoto (termina al confirmar la salida)
        # ------------------------------------------
        Enter-RemotePrompt -Session $Session -IP $IP -RemoteName $RemoteName

        $ClosedLabel = if ($RemoteName) { $RemoteName } else { $IP }
        Write-Host "Sesión con $ClosedLabel cerrada." -ForegroundColor Yellow
    }
    finally {
        # Se ejecuta siempre: salida normal, error o Ctrl+C
        if ($Session) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue }
        if ($AddedTrusted) { Remove-TrustedHostEntry -IP $IP }
    }
}

# ==========================================
# 1. BUCLE PRINCIPAL: pedir IP -> conectar -> salir del remoto -> volver a pedir IP
# ==========================================

# La MAC y el nombre esperados (si se pasaron por parámetro) se validan al inicio y solo aplican
# a la primera conexión
$PendingMac = $null
if (-not [string]::IsNullOrWhiteSpace($MacAddress)) {
    $PendingMac = ConvertTo-NormalizedMac -Text $MacAddress
    if (-not $PendingMac) {
        Write-Host "Saliendo..." -ForegroundColor Red
        exit 1
    }
}
$PendingName = $ExpectedHostName
$PendingIP   = $IP

while ($true) {
    if (-not [string]::IsNullOrWhiteSpace($PendingIP)) {
        $TargetText = $PendingIP
        $PendingIP = $null
    }
    else {
        Write-Host ''
        $TargetText = Read-Host "Introduce la IP del equipo remoto ('salir' para terminar, 'c' para cambiar credenciales)"
    }

    $TargetText = "$TargetText".Trim()

    if ($TargetText -eq '') {
        Write-Host "No se ha ingresado ninguna IP. Escribe 'salir' para terminar." -ForegroundColor Yellow
        continue
    }

    if ($TargetText -match '^(salir|exit|quit|q)$') {
        if (Read-Confirmation "¿Seguro que quieres salir del script?") { break }
        continue
    }

    if ($TargetText -match '^(c|cred|credenciales)$') {
        $script:StoredCredential = $null
        $script:StoredDomain     = $null
        $script:StoredUserName   = $null
        Write-Host "Credenciales descartadas; se pedirán en la próxima conexión." -ForegroundColor DarkGray
        continue
    }

    $TargetIP = ConvertTo-ValidIPv4 -Text $TargetText
    if (-not $TargetIP) { continue }

    # MAC y nombre esperados: solo para la primera conexión
    $ConnMac  = $PendingMac;  $PendingMac  = $null
    $ConnName = $PendingName; $PendingName = $null

    Invoke-RemoteConnection -IP $TargetIP -ExpectedMac $ConnMac -ExpectedHostName $ConnName

    Write-Host ''
    Write-Host "Conexión finalizada. Volviendo al inicio..." -ForegroundColor DarkGray
}

Write-Host "Script finalizado." -ForegroundColor DarkGray
