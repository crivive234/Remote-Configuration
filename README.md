# configure-remote.ps1

Script de PowerShell para abrir una **sesión remota interactiva** (`Enter-PSSession`) en un equipo de la red a partir de su dirección IP. Antes de conectar, prepara el servicio **WinRM** en el equipo remoto, registra la IP en **TrustedHosts** del equipo local y verifica que el remoto responda.

---

## Tabla de contenido

1. [¿Qué hace?](#qué-hace)
2. [Requisitos](#requisitos)
3. [Uso rápido](#uso-rápido)
4. [Parámetros](#parámetros)
5. [Flujo paso a paso](#flujo-paso-a-paso)
6. [Ejemplo de ejecución](#ejemplo-de-ejecución)
7. [Solución de problemas](#solución-de-problemas)
8. [Seguridad](#seguridad)
9. [Limitaciones conocidas](#limitaciones-conocidas)
10. [Cómo revertir los cambios](#cómo-revertir-los-cambios)
11. [Cambios respecto a la versión anterior](#cambios-respecto-a-la-versión-anterior)

---

## ¿Qué hace?

| # | Tarea | Dónde se ejecuta |
|---|-------|------------------|
| 1 | Obtiene y valida la IP (parámetro o `Read-Host`) | Local |
| 2 | Comprueba conectividad con `Test-Connection` (solo aviso) | Local → Remoto |
| 3 | Deja WinRM en inicio automático y lo inicia con `sc.exe` (omitible) | Remoto |
| 4 | Agrega la IP a `TrustedHosts` con comparación exacta | Local |
| 5 | Solicita dominio, usuario y contraseña (esta última oculta) | Local |
| 6 | Verifica que WinRM responda con `Test-WSMan` | Local → Remoto |
| 7 | Abre la sesión con `Enter-PSSession` | Local → Remoto |

---

## Requisitos

**Equipo local (desde donde se ejecuta):**

- Windows con PowerShell 5.1 o superior.
- PowerShell **ejecutado como administrador** (el script lo exige con `#Requires -RunAsAdministrator`).
- Conectividad de red con el equipo remoto.

**Equipo remoto:**

- Una cuenta con permisos de administrador sobre el equipo, para abrir la sesión.
- Firewall que permita **WinRM** (puerto **5985**) y, si no se usa `-SkipServiceSetup`, **RPC/SMB** (puertos 135 y 445) para `sc.exe`.
- Equipo encendido y alcanzable por IP.

---

## Uso rápido

1. Abre **PowerShell como administrador**.
2. Si es necesario, permite scripts solo en esta sesión:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```

3. Ejecuta el script:

   ```powershell
   .\configure-remote.ps1
   ```

4. Escribe la IP cuando se te solicite y luego el **dominio** (Enter para usar `ititpa.itic`), el **usuario** y la **contraseña** (no se muestra al escribir).
5. Al conectar, el prompt cambia a `[10.158.131.20]: PS C:\...>`. Para cerrar la sesión remota:

   ```powershell
   Exit-PSSession
   ```

**Otras formas de ejecutarlo:**

```powershell
# Pasando la IP directamente
.\configure-remote.ps1 -IP 10.158.131.20

# Si WinRM ya está activo en el remoto (omite sc.exe)
.\configure-remote.ps1 -IP 10.158.131.20 -SkipServiceSetup

# Indicando dominio y usuario (solo pedirá la contraseña)
.\configure-remote.ps1 -IP 10.158.131.20 -Domain ititpa.itic -UserName cristian.viasus
```

---

## Parámetros

| Parámetro | Tipo | Obligatorio | Descripción |
|-----------|------|-------------|-------------|
| `-IP` | `string` | No | IPv4 del equipo remoto. Si se omite, se solicita por pantalla. Admite uso posicional (`.\configure-remote.ps1 10.0.0.5`). |
| `-Domain` | `string` | No | Dominio del usuario. Por defecto `ititpa.itic`. Al ejecutar el script se puede aceptar con Enter o escribir otro. |
| `-UserName` | `string` | No | Usuario **sin dominio** (ej. `cristian.viasus`). Si se omite, se solicita por pantalla. También acepta `DOMINIO\usuario` o `usuario@dominio`; en ese caso no se agrega el dominio. |
| `-Credential` | `PSCredential` | No | Credencial ya construida (por ejemplo, desde `Get-Credential` o SecretManagement). Si se pasa, el script no pide dominio, usuario ni contraseña. |
| `-SkipServiceSetup` | `switch` | No | Omite el paso de `sc.exe` sobre el equipo remoto. |

---

## Flujo paso a paso

### 1. Validación de la IP

Si no se pasa `-IP`, se pide con `Read-Host`. El script termina con código `1` si el valor está vacío o no es una **IPv4 válida** (cuatro octetos entre 0 y 255).

### 2. Conectividad

Se envía un ping. Si no hay respuesta solo se muestra una advertencia, porque muchos equipos bloquean ICMP pero sí aceptan WinRM.

### 3. WinRM en el equipo remoto

```powershell
sc.exe "\\$IP" config WinRM start= auto
sc.exe "\\$IP" start WinRM
```

- Se revisa el código de salida de cada comando y se muestra una **advertencia** si fallan.
- El código `1056` (servicio ya en ejecución) se considera correcto.
- ⚠️ `sc.exe` usa la **identidad de Windows con la que ejecutas el script**, no las credenciales que escribes en el paso 5. Si tu usuario actual no es administrador del remoto, usa `-SkipServiceSetup` o activa WinRM por otro medio.

### 4. TrustedHosts

El script lee la lista actual, la separa por comas y compara **valor exacto**:

- Si la lista contiene `*`, no se modifica.
- Si la IP ya está, no se hace nada.
- En otro caso, se agrega al final.

### 5. Credenciales

Si no se pasó `-Credential`, el script pregunta en este orden:

1. **Dominio**: muestra el valor por defecto entre corchetes (`Dominio [ititpa.itic]`). Presiona Enter para aceptarlo o escribe otro.
2. **Usuario**: sin dominio (por ejemplo `cristian.viasus`). Si ya lo escribes como `DOMINIO\usuario` o `usuario@dominio`, el script lo usa tal cual.
3. **Contraseña**: se escribe oculta (`Read-Host -AsSecureString`) y nunca se guarda en texto plano.

Con eso arma el usuario completo (`ititpa.itic\cristian.viasus`) y crea el `PSCredential`. Si el usuario o la contraseña quedan vacíos, el script termina.

### 6. Verificación de WinRM

`Test-WSMan` confirma que el servicio responde antes de intentar la sesión, para dar un mensaje de error claro si no lo hace.

### 7. Sesión interactiva

```powershell
Enter-PSSession -ComputerName $IP -Credential $Credential
```

Es la **última instrucción** del script: al terminar, quedas en el prompt remoto hasta que ejecutes `Exit-PSSession`.

---

## Ejemplo de ejecución

```
PS C:\> .\configure-remote.ps1
Introduce la IP del equipo remoto: 10.158.131.20
Verificando e iniciando el servicio WinRM en 10.158.131.20...
IP 10.158.131.20 agregada a TrustedHosts.
Dominio [ititpa.itic]:
Usuario (sin dominio): cristian.viasus
Contraseña de ititpa.itic\cristian.viasus: ********
Conectando al equipo 10.158.131.20...
[10.158.131.20]: PS C:\Users\admin\Documents> hostname
PC-EJEMPLO-01
[10.158.131.20]: PS C:\Users\admin\Documents> Exit-PSSession
PS C:\>
```

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|----------------|----------|
| `#Requires` / "requiere elevación" al ejecutar | PowerShell sin privilegios de administrador | Abrir PowerShell **como administrador** |
| "'X' no es una dirección IPv4 válida" | IP mal escrita o se ingresó un nombre de host | Escribir una IPv4 con formato `n.n.n.n` |
| "No se pudo leer la configuración local de WinRM" | WinRM local sin configurar | `Enable-PSRemoting -Force` |
| Advertencia de `sc.exe` con código **5** | Acceso denegado: tu usuario actual no es administrador del remoto | Usar `-SkipServiceSetup` o ejecutar PowerShell con una cuenta con permisos |
| Advertencia de `sc.exe` con código **1722** | Servidor RPC no disponible (equipo apagado o puertos 135/445 bloqueados) | Revisar firewall y conectividad |
| "WinRM no responde en ..." | Servicio detenido, puerto 5985 bloqueado o equipo apagado | `Test-NetConnection <IP> -Port 5985` y revisar firewall |
| "No se pudo abrir la sesión" con acceso denegado | Usuario sin permisos, contraseña incorrecta o formato de usuario no aceptado | Verificar credenciales y pertenencia a administradores del remoto. Si el dominio completo falla, prueba el nombre corto (NetBIOS) o el formato `usuario@ititpa.itic` |

**Comandos útiles de diagnóstico:**

```powershell
Test-NetConnection -ComputerName <IP> -Port 5985
Test-WSMan -ComputerName <IP>
sc.exe \\<IP> query WinRM
Get-Item WSMan:\localhost\Client\TrustedHosts
```

---

## Seguridad

- **Sin contraseñas en el código.** La versión anterior tenía una contraseña en texto plano; esta pide dominio, usuario y contraseña al ejecutarse, y la contraseña se maneja como `SecureString`. Si esa contraseña llegó a compartirse o guardarse fuera de un lugar controlado, **cámbiala**.
- **No uses `*` en TrustedHosts.** Hace que el equipo confíe en cualquier destino y facilita ataques de suplantación. El script nunca lo agrega y, si ya existe, no lo toca.
- **TrustedHosts es acumulativo.** Cada IP agregada permanece hasta que la quites ([ver cómo](#cómo-revertir-los-cambios)).
- **Conexión por IP = autenticación NTLM**, no Kerberos. Si es posible, conéctate por nombre de host del dominio.
- Si necesitas automatizar sin interacción, usa `Microsoft.PowerShell.SecretManagement` y pasa el resultado con `-Credential`, en lugar de escribir la clave en el script.
- Usa el script **solo en equipos sobre los que tengas autorización**.

---

## Limitaciones conocidas

- Solo acepta **IPv4**, no nombres de host ni IPv6.
- Usa HTTP (5985); no contempla HTTPS (5986).
- `sc.exe` no usa la credencial ingresada, sino la sesión actual de Windows.
- Las entradas agregadas a `TrustedHosts` **no se eliminan automáticamente** al terminar. Como `Enter-PSSession` deja el prompt remoto al finalizar el script, no es posible ejecutar una limpieza fiable "después" de la sesión.
- Si no hay respuesta de ping, el script continúa (puede ser un bloqueo de ICMP).

---

## Cómo revertir los cambios

**Quitar una IP de TrustedHosts (equipo local, PowerShell como administrador):**

```powershell
$ip = '10.158.131.20'
$lista = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value -split ',' |
         ForEach-Object { $_.Trim() } |
         Where-Object { $_ -and $_ -ne $ip }
Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($lista -join ',') -Force
```

**Vaciar TrustedHosts por completo:**

```powershell
Clear-Item WSMan:\localhost\Client\TrustedHosts -Force
```

**Devolver WinRM a inicio manual en el equipo remoto (opcional):**

```powershell
sc.exe \\<IP> config WinRM start= demand
sc.exe \\<IP> stop WinRM
```

---

## Cambios respecto a la versión anterior

| Antes | Ahora |
|-------|-------|
| Contraseña y usuario fijos en el código | Se piden dominio, usuario y contraseña oculta (o se usa `-Credential`) |
| Sin validación de la IP | Validación de formato IPv4 |
| Errores de `sc.exe` silenciados | Se revisa el código de salida y se advierte |
| `-notlike "*$IP*"` (coincidencia parcial) | Comparación exacta sobre la lista |
| Reemplazaba `*` en TrustedHosts por la IP | Respeta `*` y no modifica la lista |
| Sin comprobación de privilegios | `#Requires -RunAsAdministrator` |
| Error genérico si WinRM fallaba | `Test-WSMan` previo y mensajes de error claros |
| Sin parámetros | `-IP`, `-Domain`, `-UserName`, `-Credential`, `-SkipServiceSetup` |
