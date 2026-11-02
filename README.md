# configure-remote.ps1

Script de PowerShell para abrir una **sesión remota interactiva** (`Enter-PSSession`) en un equipo de la red a partir de su dirección IP. Antes de conectar, prepara el servicio **WinRM** en el equipo remoto, registra la IP en **TrustedHosts** del equipo local, verifica que el remoto responda y genera el comando exacto para restaurar la seguridad al terminar.

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
| 2 | Comprueba conectividad con `Test-Connection` y verifica MAC opcionalmente | Local → Remoto |
| 3 | Solicita dominio, usuario y contraseña (esta última oculta) | Local |
| 4 | Deja WinRM en inicio automático y lo inicia mediante CIM/DCOM (omitible) | Remoto |
| 5 | Agrega temporalmente la IP a `TrustedHosts` con comparación exacta | Local |
| 6 | Verifica que WinRM responda con `Test-WSMan` | Local → Remoto |
| 7 | Verifica el nombre del equipo (si se especifica `-ExpectedHostName`) | Remoto |
| 8 | Abre la sesión con `Enter-PSSession` y genera el comando de limpieza | Local → Remoto |

---

## Requisitos

**Equipo local (desde donde se ejecuta):**

- Windows con PowerShell 5.1 o superior.
- PowerShell **ejecutado como administrador** (el script lo exige con `#Requires -RunAsAdministrator`).
- Conectividad de red con el equipo remoto.

**Equipo remoto:**

- Una cuenta con permisos de administrador sobre el equipo, para abrir la sesión.
- Firewall que permita **WinRM** (puerto **5985**) y, si no se usa `-SkipServiceSetup`, **DCOM/RPC** (puertos 135 y dinámicos) para el inicio remoto del servicio.
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

4. Escribe la IP cuando se te solicite y luego el **dominio** (Enter para usar el sugerido), el **usuario** y la **contraseña** (no se muestra al escribir).
5. El script imprimirá un comando en color cyan para limpiar tu `TrustedHosts`. Cópialo.
6. Al conectar, el prompt cambia a `[IP]: PS C:\...>`. Para cerrar la sesión remota:

   ```powershell
   Exit-PSSession
   ```
7. Pega y ejecuta localmente el comando cyan que copiaste en el paso 5.
8. Elimina la sesión huérfana localmente con `Remove-PSSession -Id <ID>` (el script te indicará el ID).

**Otras formas de ejecutarlo:**

```powershell
# Pasando la IP directamente
.\configure-remote.ps1 -IP 10.158.132.190

# Si WinRM ya está activo en el remoto (omite el inicio del servicio)
.\configure-remote.ps1 -IP 10.158.132.190 -SkipServiceSetup

# Verificando la identidad del equipo destino por MAC y nombre antes de conectar
.\configure-remote.ps1 -IP 10.158.132.190 -MacAddress AA-BB-CC-DD-EE-FF -ExpectedHostName OTD-80P7TM-155
```

---

## Parámetros

| Parámetro | Tipo | Obligatorio | Descripción |
|-----------|------|-------------|-------------|
| `-IP` | `string` | No | IPv4 del equipo remoto. Si se omite, se solicita por pantalla. Admite uso posicional. |
| `-Domain` | `string` | No | Dominio del usuario. Al ejecutar, sugiere el dominio actual del entorno. |
| `-UserName` | `string` | No | Usuario **sin dominio**. Si se omite, se solicita por pantalla. Acepta formatos `DOMINIO\usuario` o `usuario@dominio`. |
| `-Credential` | `PSCredential` | No | Credencial ya construida. Si se pasa, no pide dominio, usuario ni contraseña. |
| `-MacAddress` | `string` | No | MAC esperada del equipo. Si no coincide con la red local, el script aborta antes de enviar credenciales. |
| `-ExpectedHostName` | `string` | No | Nombre de equipo esperado. Se verifica después de iniciar sesión; si difiere, cierra la sesión. |
| `-SkipServiceSetup` | `switch` | No | Omite el intento de iniciar WinRM en el remoto mediante CIM/DCOM. |
| `-EnableAutoStart` | `switch` | No | Configura el servicio WinRM remoto para que inicie automáticamente. |
| `-Force` | `switch` | No | Omite la confirmación manual [S/n] antes de agregar la IP a TrustedHosts. |

---

## Flujo paso a paso

### 1. Validación de la IP

Si no se pasa `-IP`, se pide con `Read-Host`. Valida que sea una **IPv4 estricta** (sin ceros a la izquierda y descartando direcciones reservadas/loopback).

### 2. Conectividad e Identidad Preventiva

Se envía un ping. Adicionalmente, si se especifica `-MacAddress`, borra la caché ARP local y verifica que la MAC actual de la IP coincida con la esperada, protegiendo contra cambios de lease DHCP.

### 3. Credenciales

Si no se pasó `-Credential`, solicita dominio (sugiriendo el actual), usuario y contraseña (como `SecureString`).

### 4. WinRM en el equipo remoto

Intenta iniciar el servicio remotamente utilizando **CIM sobre DCOM**, autenticándose con las credenciales suministradas (no con las del usuario que ejecuta el script localmente). 

### 5. TrustedHosts

Verifica la lista local y, si la IP no está, la agrega. Pide confirmación previa a menos que se use `-Force`. 

### 6. Verificación y Sesión Interactiva

Confirma que WinRM responda (`Test-WSMan`) y establece la conexión. Si se usó `-ExpectedHostName`, coteja que sea el host correcto.

### 7. Generación de Limpieza

Calcula el estado original de `TrustedHosts` e **imprime el comando exacto en color cyan** para que puedas revertir el cambio manualmente. Al finalizar, transfiere el control a `Enter-PSSession`.

---

## Ejemplo de ejecución

```
PS C:\> .\configure-remote.ps1
Introduce la IP del equipo remoto: 10.158.132.190
Dominio [ITITPA.ITIC]: ititpa.itic
Usuario (sin dominio): cristian.viasus
Contraseña de ititpa.itic\cristian.viasus: ******************
Verificando e iniciando el servicio WinRM en 10.158.132.190...
Se agregará 10.158.132.190 a TrustedHosts solo durante la conexión y se retirará después. ¿Continuar? [S/n]: S
IP 10.158.132.190 agregada temporalmente a TrustedHosts.
Conectando al equipo 10.158.132.190...
Equipo remoto: OTD-80P7TM-155
ATENCIÓN: Para retirar la IP de TrustedHosts al terminar, copia y ejecuta localmente este comando:
Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value '' -Force
Al terminar: Exit-PSSession  y luego  Remove-PSSession -Id 1
[10.158.132.190]: PS C:\> hostname
OTD-80P7TM-155
[10.158.132.190]: PS C:\> Exit-PSSession
PS C:\> Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value '' -Force
PS C:\> Remove-PSSession -Id 1
```

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|----------------|----------|
| `#Requires` / "requiere elevación" | PowerShell sin privilegios de administrador | Abrir PowerShell **como administrador** |
| Error `0x8009030e` / "logon session does not exist" | Se retiró la IP de `TrustedHosts` mientras la sesión estaba activa | Asegúrate de no limpiar `TrustedHosts` hasta **después** de ejecutar `Exit-PSSession` |
| Fallo al gestionar WinRM remoto | CIM/DCOM bloqueado (puerto 135) o falta de permisos | Usar `-SkipServiceSetup` o revisar el firewall remoto |
| "WinRM no responde en ..." | WinRM detenido o puerto 5985 bloqueado | Revisar firewall o ejecutar `Test-NetConnection <IP> -Port 5985` |
| Access Denied al abrir sesión | Credenciales incorrectas o el usuario no es admin | Verificar contraseña y pertenencia al grupo Administradores local del destino |

---

## Seguridad

- **Sin contraseñas guardadas**: Todo se maneja dinámicamente en memoria mediante objetos `SecureString` y `PSCredential`.
- **Validaciones cruzadas**: Soporta verificación de MAC y Hostname para mitigar conexiones erróneas si la IP (lease DHCP) fue reasignada a otro equipo.
- **Autenticación NTLM**: La conexión directa por IP fuerza el uso de NTLM. Como el servidor remoto no se autentica ante ti de forma nativa (como sí lo haría Kerberos), es crucial limpiar `TrustedHosts` al terminar.
- **TrustedHosts es acumulativo**: La instrucción en cyan que entrega el script está pre-calculada para dejar tu lista exactamente como estaba antes de ejecutarlo. Asegúrate de ejecutarla al terminar tu trabajo.

---

## Limitaciones conocidas

- Solo acepta **IPv4**, no nombres de host ni IPv6.
- Usa HTTP (5985); no contempla HTTPS (5986).
- **Limpieza manual obligatoria**: Debido a que el script finaliza delegando el control a la consola interactiva (`Enter-PSSession`), es técnicamente imposible que el mismo script elimine automáticamente la IP de `TrustedHosts` tras salir de la sesión sin romper la autenticación NTLM en el proceso. Debe hacerse copiando y pegando el comando proporcionado.

---

## Cómo revertir los cambios

Si olvidaste copiar el comando proporcionado por el script, puedes limpiar la IP manualmente:

**Quitar una IP específica (ejemplo 10.158.132.190):**
```powershell
$ip = '10.158.132.190'
$lista = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value -split ',' |
         ForEach-Object { $_.Trim() } |
         Where-Object { $_ -and $_ -ne $ip }
Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($lista -join ',') -Force
```

**Vaciar TrustedHosts por completo:**
```powershell
Clear-Item WSMan:\localhost\Client\TrustedHosts -Force
```

---

## Cambios respecto a la versión anterior

| Antes | Ahora |
|-------|-------|
| Contraseña y usuario fijos en el código | Se piden dominio, usuario y contraseña oculta (o se usa `-Credential`) |
| Activación remota usando `sc.exe` | Activación remota moderna utilizando **CIM (DCOM)** con las credenciales provistas |
| Limpieza automática de TrustedHosts | **Comando de limpieza generado manualmente** para evitar el error `0x8009030e` que rompía la sesión interactiva NTLM |
| Sin verificación de identidad | Soporte opcional de verificación cruzada mediante `-MacAddress` y `-ExpectedHostName` |
| Sin advertencia de limpieza | El script indica los comandos exactos de limpieza (`Set-Item` y `Remove-PSSession`) antes de abrir la consola |