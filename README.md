# configure-remote.ps1

Script de PowerShell para abrir **sesiones remotas interactivas** en equipos de la red a partir de su dirección IP, **una tras otra en bucle**. Antes de conectar, prepara el servicio **WinRM** en el equipo remoto, registra la IP en **TrustedHosts** del equipo local de forma temporal y verifica que el remoto responda. Al salir del remoto (con confirmación), cierra la sesión, **retira la IP de TrustedHosts automáticamente** y vuelve a pedir una IP. Incluye un lanzador `configure-remote.bat` que se eleva a administrador por sí solo y no requiere configurar la política de ejecución.

---

## Tabla de contenido

1. [¿Qué hace?](#qué-hace)
2. [Requisitos](#requisitos)
3. [Uso rápido](#uso-rápido)
4. [Lanzador .bat](#lanzador-bat)
5. [Parámetros](#parámetros)
6. [Flujo paso a paso](#flujo-paso-a-paso)
7. [Prompt remoto y comandos especiales](#prompt-remoto-y-comandos-especiales)
8. [Ejemplo de ejecución](#ejemplo-de-ejecución)
9. [Solución de problemas](#solución-de-problemas)
10. [Seguridad](#seguridad)
11. [Limitaciones conocidas](#limitaciones-conocidas)
12. [Cómo revertir los cambios](#cómo-revertir-los-cambios)
13. [Cambios respecto a la versión anterior](#cambios-respecto-a-la-versión-anterior)

---

## ¿Qué hace?

El script trabaja en **bucle**: pide una IP, abre la sesión remota y, cuando sales de ella, vuelve a pedir otra IP. Para terminar se escribe `salir` en el prompt de la IP. Por cada equipo realiza estas tareas:

| # | Tarea | Dónde se ejecuta |
|---|-------|------------------|
| 1 | Obtiene y valida la IP (parámetro la primera vez; después `Read-Host`) | Local |
| 2 | Comprueba conectividad con `Test-Connection`, verifica la MAC opcionalmente y prueba los puertos 5985 (WinRM) y 135 (DCOM) | Local → Remoto |
| 3 | Solicita dominio, usuario y contraseña **una sola vez** y los reutiliza en memoria | Local |
| 4 | Si WinRM aún no responde, lo inicia mediante CIM/DCOM (omitible). El inicio automático solo con `-EnableAutoStart` | Remoto |
| 5 | Agrega temporalmente la IP a `TrustedHosts` con comparación exacta | Local |
| 6 | Verifica que WinRM responda con `Test-WSMan` y crea la sesión | Local → Remoto |
| 7 | Verifica el nombre del equipo (si se especifica `-ExpectedHostName`) | Remoto |
| 8 | Abre un prompt remoto propio; `exit` o `salir` piden confirmación | Local → Remoto |
| 9 | Al salir: cierra la sesión, retira la IP de `TrustedHosts` y vuelve al paso 1 | Local |

---

## Requisitos

**Equipo local (desde donde se ejecuta):**

- Windows con PowerShell 5.1 o superior.
- PowerShell **ejecutado como administrador** (el script lo exige con `#Requires -RunAsAdministrator`). Si usas el [lanzador .bat](#lanzador-bat), él se encarga de elevarse.
- Conectividad de red con el equipo remoto.
- Para usar el lanzador: `configure-remote.bat` en la **misma carpeta** que `configure-remote.ps1`.

**Equipo remoto:**

- Una cuenta con permisos de administrador sobre el equipo, para abrir la sesión.
- Firewall que permita **WinRM** (puerto **5985**) y, si no se usa `-SkipServiceSetup`, **DCOM/RPC** (puertos 135 y dinámicos) para el inicio remoto del servicio.
- Equipo encendido y alcanzable por IP.

---

## Uso rápido

Hay dos formas de iniciar el script; a partir de ahí el funcionamiento es el mismo.

**Opción A: con el lanzador `configure-remote.bat` (recomendada).** Haz doble clic en `configure-remote.bat` (guardado junto a `configure-remote.ps1`) y acepta el aviso de control de cuentas (UAC). El lanzador se eleva a administrador y aplica `ExecutionPolicy Bypass` solo a ese proceso. Más detalles en [Lanzador .bat](#lanzador-bat).

**Opción B: desde PowerShell.**

1. Abre **PowerShell como administrador**.
2. Si es necesario, permite scripts solo en esta sesión:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```

3. Ejecuta el script:

   ```powershell
   .\configure-remote.ps1
   ```

**Una vez iniciado el script:**

1. Escribe la IP cuando se te solicite. **La primera vez** también se piden el **dominio** (Enter para usar el sugerido), el **usuario** y la **contraseña** (no se muestra al escribir). Se reutilizan en las siguientes conexiones hasta que cierres el script.
2. Si la IP no estaba en `TrustedHosts`, el script pide confirmación `[S/n]` antes de agregarla (se omite con `-Force`).
3. Al conectar aparece el prompt `[EQUIPO] PS C:\...>`. Cada línea que escribas se ejecuta en el equipo remoto.
4. Para salir del remoto escribe `exit` o `salir` y confirma con `S`. Si respondes `n`, sigues en la misma sesión.
5. El script cierra la sesión, retira la IP de `TrustedHosts` y **vuelve a pedir una IP**. Para conectarte a otro equipo escribe su IP; para terminar el script escribe `salir` y confirma.

> En todas las confirmaciones, pulsar **Enter** equivale a responder `S`.

**Otras formas de ejecutarlo:**

```powershell
# Pasando la IP directamente (para la primera conexión)
.\configure-remote.ps1 -IP 10.158.132.190

# Si WinRM ya está activo en el remoto (omite el inicio del servicio)
.\configure-remote.ps1 -IP 10.158.132.190 -SkipServiceSetup

# Verificando la identidad del equipo destino por MAC y nombre antes de conectar
.\configure-remote.ps1 -IP 10.158.132.190 -MacAddress AA-BB-CC-DD-EE-FF -ExpectedHostName OTD-80P7TM-155
```

Con el lanzador, los mismos argumentos se escriben después del nombre del `.bat` (ver [Lanzador .bat](#lanzador-bat)):

```bat
configure-remote.bat 10.158.132.190
configure-remote.bat 10.158.132.190 -SkipServiceSetup
```

---

## Lanzador .bat

`configure-remote.bat` es un lanzador para ejecutar el script con doble clic, sin abrir PowerShell a mano. Debe estar en la **misma carpeta** que `configure-remote.ps1`.

| Qué hace | Detalle |
|----------|---------|
| Localiza el script | Busca `configure-remote.ps1` en su propia carpeta. Si no lo encuentra, muestra `No se encontro el script`, la ruta esperada y termina con código 1 |
| Se eleva solo | Comprueba si ya tiene permisos de administrador (`net session`). Si no, se relanza con UAC (`-Verb RunAs`) pasando los mismos argumentos |
| Política de ejecución | Abre PowerShell con `-NoProfile -ExecutionPolicy Bypass`, que aplica **solo a ese proceso**; no cambia la política del equipo |
| Pasa los argumentos | Todo lo que escribas después del nombre del `.bat` se entrega al script tal cual (`%*`) |
| Cierra al terminar | Ya no usa `-NoExit`: al terminar el script (con `salir` y confirmación) la ventana se cierra sola |
| Pausa si hay error | Si el script termina con un código distinto de 0 (por ejemplo, un `-MacAddress` inválido), muestra `El script termino con codigo N` y espera una tecla, para que puedas leer el mensaje |

**Ejemplos:**

```bat
:: Sin argumentos: el script pide la IP
configure-remote.bat

:: Con la IP para la primera conexión
configure-remote.bat 10.158.132.190

:: Con la IP y otros parámetros del script
configure-remote.bat 10.158.132.190 -SkipServiceSetup
```

**Notas:**

- Con el lanzador no necesitas abrir PowerShell como administrador ni ejecutar `Set-ExecutionPolicy`.
- Si cancelas el aviso de UAC, el script no se ejecuta.
- Al elevarse, la ventana original termina y se abre una nueva con permisos de administrador.

---

## Parámetros

Con el [lanzador .bat](#lanzador-bat), estos parámetros se escriben después del nombre del `.bat`.

| Parámetro | Tipo | Obligatorio | Descripción |
|-----------|------|-------------|-------------|
| `-IP` | `string` | No | IPv4 del equipo remoto para la **primera** conexión. Si se omite, se solicita por pantalla. Admite uso posicional. Después de cada sesión el script vuelve a pedir una IP. |
| `-Domain` | `string` | No | Dominio del usuario. Al ejecutar, sugiere el dominio actual del entorno. Se reutiliza en las siguientes conexiones. |
| `-UserName` | `string` | No | Usuario **sin dominio**. Si se omite, se solicita por pantalla. Acepta formatos `DOMINIO\usuario` o `usuario@dominio`. Se reutiliza en las siguientes conexiones. |
| `-Credential` | `PSCredential` | No | Credencial ya construida. Si se pasa, no pide dominio, usuario ni contraseña, y se reutiliza en todas las conexiones. |
| `-MacAddress` | `string` | No | MAC esperada del equipo de la **primera** conexión. Si no coincide con la red local, esa conexión se cancela antes de enviar credenciales. No aplica a las IP siguientes. |
| `-ExpectedHostName` | `string` | No | Nombre de equipo esperado en la **primera** conexión. Se verifica después de abrir la sesión; si difiere, la cierra y vuelve al inicio. No aplica a las IP siguientes. |
| `-SkipServiceSetup` | `switch` | No | Omite el intento de iniciar WinRM en el remoto mediante CIM/DCOM (en todas las conexiones). Si WinRM (5985) tampoco responde, el script avisa y pregunta antes de continuar. |
| `-EnableAutoStart` | `switch` | No | Además de iniciar WinRM, lo deja en inicio automático en el remoto. Por defecto **no** se cambia el tipo de inicio. Requiere que DCOM (135) responda, aunque WinRM ya esté activo. |
| `-Force` | `switch` | No | Omite la confirmación `[S/n]` antes de agregar la IP a `TrustedHosts`. No afecta a las confirmaciones de salida. |

---

## Flujo paso a paso

### 1. Bucle principal y validación de la IP

Si no se pasa `-IP`, se pide con `Read-Host`. Valida que sea una **IPv4 estricta** (sin ceros a la izquierda y descartando direcciones reservadas, loopback y multicast). Si la IP no es válida, muestra el error y **vuelve a preguntar** (ya no cierra el script). Una entrada vacía tampoco cierra el script: vuelve a preguntar.

Cuando termina una conexión, el script regresa a este paso.

### 2. Conectividad e identidad preventiva

Se envía un ping (si no responde, solo avisa y continúa). Si se especificó `-MacAddress`, borra la caché ARP local y verifica que la MAC actual de la IP coincida con la esperada, protegiendo contra cambios de lease DHCP. El formato de `-MacAddress` se valida al iniciar el script; si es inválido, el script termina con código de salida 1.

Después prueba los puertos **5985** (WinRM) y **135** (DCOM) en paralelo, con un tiempo máximo de 2 segundos, **antes de pedir credenciales**:

| Resultado | Qué hace el script |
|-----------|--------------------|
| 5985 responde | Continúa y omite el inicio remoto del servicio, porque WinRM ya está activo. Con `-EnableAutoStart` y 135 abierto sí lo ejecuta para configurar el inicio automático; si 135 está cerrado, avisa de que no puede aplicarlo |
| 5985 no responde y 135 sí | Continúa e intenta iniciar WinRM por DCOM (paso 4) |
| Ninguno responde | Avisa de que el equipo puede estar apagado, en otra red o con el firewall bloqueando, y pregunta `¿Intentar conectar de todos modos? [s/N]`. Por defecto cancela y vuelve a pedir la IP |
| 5985 no responde, 135 sí, y se usó `-SkipServiceSetup` | Igual que el caso anterior: avisa que el servicio no se iniciará y pregunta `[s/N]` |

### 3. Credenciales

La primera vez que se llega a este paso, se solicitan dominio (sugiriendo el actual), usuario y contraseña (como `SecureString`). Quedan **en memoria hasta que el script se cierre**, y se usan en las conexiones siguientes sin volver a preguntar. Para cambiarlas, escribe `c` en el prompt de la IP.

### 4. WinRM en el equipo remoto

Si WinRM no respondía y DCOM sí (o se pidió `-EnableAutoStart`), intenta iniciar el servicio remotamente utilizando **CIM sobre DCOM**, autenticándose con las credenciales suministradas (no con las del usuario que ejecuta el script localmente). Por defecto **solo inicia** el servicio; con `-EnableAutoStart` además lo deja en inicio automático. Si falla, avisa y continúa de todos modos. Ver [Si WinRM no se puede iniciar de forma remota](#si-winrm-no-se-puede-iniciar-de-forma-remota).

### 5. TrustedHosts

Verifica la lista local:

- Si contiene `*`, avisa y no modifica nada.
- Si la IP ya estaba, no la modifica **ni la retira** al terminar.
- Si no estaba, pide confirmación (salvo `-Force`) y la agrega solo mientras dura la conexión.

### 6. Verificación y sesión

Confirma que WinRM responda (`Test-WSMan`, hasta 3 intentos con 2 segundos de espera) y crea la sesión con `New-PSSession`. Si se usó `-ExpectedHostName`, coteja que el nombre real del equipo sea el esperado; si no, cierra la sesión y vuelve al inicio.

### 7. Prompt remoto

Abre el prompt remoto propio descrito en la [sección siguiente](#prompt-remoto-y-comandos-especiales). Termina cuando confirmas la salida o cuando la sesión deja de estar activa.

### 8. Cierre y limpieza automática

Al terminar, por cualquier camino (salida normal, error o `Ctrl+C`), el script:

1. Elimina la sesión con `Remove-PSSession`.
2. Retira la IP de `TrustedHosts` (solo si la agregó él).
3. Vuelve al paso 1 y pide una nueva IP.

El orden importa: la IP se retira **después** de cerrar la sesión, para evitar el error `0x8009030e`.

---

## Prompt remoto y comandos especiales

El script **no usa `Enter-PSSession`**. Ese comando no devuelve el control al script cuando sales de la sesión remota, por lo que no sería posible volver al inicio ni pedir confirmación. En su lugar, el script muestra su propio prompt, `[EQUIPO] PS ruta>`, y ejecuta cada línea en la sesión remota (el directorio actual del remoto se refleja en el prompt).

**En el prompt remoto:**

| Entrada | Efecto |
|---------|--------|
| `exit`, `salir`, `quit` o `Exit-PSSession` | Pide confirmación para cerrar la sesión. Con `S` cierra y vuelve a pedir una IP; con `n` sigues en la misma sesión |
| `cls`, `clear` o `Clear-Host` | Limpia la pantalla local |
| Línea vacía | Se ignora |
| Cualquier otra línea | Se ejecuta en el equipo remoto |

**En el prompt de la IP:**

| Entrada | Efecto |
|---------|--------|
| Una IPv4 válida | Inicia la conexión a ese equipo |
| `salir`, `exit`, `quit` o `q` | Pide confirmación para terminar el script |
| `c`, `cred` o `credenciales` | Descarta dominio, usuario y contraseña de la memoria; se pedirán en la próxima conexión |
| Entrada vacía | Vuelve a preguntar |

**Diferencias frente a `Enter-PSSession`:**

- Se ejecuta **un comando por línea**.
- No hay autocompletado con Tab.
- No sirven los programas que piden entrada interactiva (por ejemplo `ping -t` o un `Read-Host` remoto).
- Si un comando se queda colgado, `Ctrl+C` cierra el script; la limpieza de sesión y `TrustedHosts` se ejecuta igualmente.
- Si la sesión se pierde (el equipo se reinició o se cayó la red), el script lo avisa y vuelve al inicio.

---

## Ejemplo de ejecución

```
PS C:\> .\configure-remote.ps1

Introduce la IP del equipo remoto ('salir' para terminar, 'c' para cambiar credenciales): 10.158.132.190
Comprobando puertos en 10.158.132.190 (WinRM 5985 / DCOM 135)...
WinRM (5985) responde en 10.158.132.190.
El servicio ya está activo; se omite el inicio remoto.
Dominio [ITITPA.ITIC]: ititpa.itic
Usuario (sin dominio): cristian.viasus
Contraseña de ititpa.itic\cristian.viasus: ******************
Se agregará 10.158.132.190 a TrustedHosts solo durante la conexión y se retirará al salir. ¿Continuar? [S/n]: S
IP 10.158.132.190 agregada temporalmente a TrustedHosts.
Conectando al equipo 10.158.132.190...
Equipo remoto: OTD-80P7TM-155

Sesión remota abierta en OTD-80P7TM-155 (10.158.132.190). Escribe 'exit' o 'salir' para cerrarla (se pedirá confirmación).
Un comando por línea; sin autocompletado con Tab ni programas interactivos.
[OTD-80P7TM-155] PS C:\Users\cristian.viasus\Documents> hostname
OTD-80P7TM-155
[OTD-80P7TM-155] PS C:\Users\cristian.viasus\Documents> exit
¿Cerrar la sesión con OTD-80P7TM-155 (10.158.132.190)? [S/n]: S
Sesión con OTD-80P7TM-155 cerrada.
IP 10.158.132.190 retirada de TrustedHosts.

Conexión finalizada. Volviendo al inicio...

Introduce la IP del equipo remoto ('salir' para terminar, 'c' para cambiar credenciales): salir
¿Seguro que quieres salir del script? [S/n]: S
Script finalizado.
```

**Ejemplo con un equipo inalcanzable** (no se piden credenciales):

```
Introduce la IP del equipo remoto ('salir' para terminar, 'c' para cambiar credenciales): 10.158.135.163
Comprobando puertos en 10.158.135.163 (WinRM 5985 / DCOM 135)...
No se alcanzan los puertos 5985 (WinRM) ni 135 (DCOM) en 10.158.135.163: el equipo puede estar apagado, en otra red o con el firewall bloqueando.
Si está encendido, activa WinRM en el propio equipo con 'Enable-PSRemoting -Force' (ver README).
¿Intentar conectar de todos modos? [s/N]: n
Conexión cancelada.

Conexión finalizada. Volviendo al inicio...
```

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|----------------|----------|
| `#Requires` / "requiere elevación" | PowerShell sin privilegios de administrador | Abrir PowerShell **como administrador**, o usar el [lanzador .bat](#lanzador-bat), que se eleva solo |
| `No se encontro el script` (lanzador .bat) | `configure-remote.bat` no está en la misma carpeta que `configure-remote.ps1` | Guardar ambos archivos juntos |
| El lanzador no abre nada tras el aviso de UAC | Se canceló el aviso de control de cuentas | Volver a ejecutar el `.bat` y aceptar el aviso |
| El lanzador muestra `El script termino con codigo N` y espera una tecla | El script terminó con error (por ejemplo, un `-MacAddress` inválido da código 1) | Lee el mensaje anterior, corrige y vuelve a ejecutar |
| Error `0x8009030e` / "logon session does not exist" | Se modificó `TrustedHosts` a mano mientras la sesión estaba activa | No debería ocurrir con el script, que retira la IP después de cerrar la sesión. No edites `TrustedHosts` mientras estás conectado |
| `WARNING: ... no responde a ping` | El equipo está apagado o bloquea ICMP | Es solo un aviso; el script continúa. Si además falla WinRM, revisa que el equipo esté encendido y alcanzable |
| `No se alcanzan los puertos 5985 (WinRM) ni 135 (DCOM)` | El equipo está apagado, en otra red o con el firewall bloqueando ambos puertos | Verifica que esté encendido y alcanzable; si lo está, activa WinRM en el propio equipo (ver [Si WinRM no se puede iniciar de forma remota](#si-winrm-no-se-puede-iniciar-de-forma-remota)). Si crees que fue un falso negativo, responde `s` a `¿Intentar conectar de todos modos?` |
| `No se pudo gestionar WinRM en ... Timed out` | CIM/DCOM bloqueado (puerto 135) o equipo inalcanzable | Usar `-SkipServiceSetup` o ver [Si WinRM no se puede iniciar de forma remota](#si-winrm-no-se-puede-iniciar-de-forma-remota) |
| "WinRM no responde en ..." | WinRM detenido o puerto 5985 bloqueado | Revisar firewall o ejecutar `Test-NetConnection <IP> -Port 5985` |
| Access Denied al abrir sesión | Credenciales incorrectas o el usuario no es admin | Escribe `c` en el prompt de la IP para volver a ingresar las credenciales y verifica la pertenencia al grupo Administradores local del destino |
| "La sesión remota ... ya no está activa" | El equipo se reinició o se perdió la red | El script vuelve al inicio; conéctate de nuevo |
| "No se pudo retirar ... de TrustedHosts" | Error al modificar la configuración local de WinRM | Seguir [Cómo revertir los cambios](#cómo-revertir-los-cambios) |

### Si WinRM no se puede iniciar de forma remota

La falta de respuesta a ping o el aviso `Timed out` del paso 4 **no significan necesariamente que WinRM esté apagado**. Desde esta versión el script comprueba los puertos 5985 y 135 antes de pedir credenciales (ver [Flujo paso a paso](#flujo-paso-a-paso)) y te avisa si ninguno responde. Para comprobarlos a mano desde tu equipo:

```powershell
Test-NetConnection 10.158.135.163 -Port 5985    # WinRM
Test-NetConnection 10.158.135.163 -Port 135     # DCOM (el que usa el script para iniciar el servicio)
```

- Si el **5985** responde `True`, WinRM ya está activo: el script lo detecta y omite el inicio remoto del servicio.
- Si ambos responden `False`, el equipo probablemente está apagado, en otra red o con el firewall bloqueando. El script lo avisa y pregunta antes de continuar; para dejarlo listo hay que actuar en el propio equipo o por GPO.

**Desde el propio equipo remoto** (PowerShell como administrador):

```powershell
# Opción 1: dejar WinRM listo de una vez (servicio, inicio automático, listener y firewall)
Enable-PSRemoting -Force
# Si la red está en perfil "Pública":
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Opción 2: solo iniciar el servicio
Start-Service WinRM
Set-Service WinRM -StartupType Automatic    # opcional: que arranque solo tras reiniciar

# Verificar
Get-Service WinRM
Test-WSMan localhost

# Si el firewall sigue bloqueando el 5985
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"
```

**Alternativa desde tu equipo**, que va por RPC/SMB (puerto 445) en lugar del 135 y a veces funciona cuando DCOM da `Timed out`:

```powershell
sc.exe \\10.158.135.163 start WinRM
```

---

## Seguridad

- **Sin contraseñas guardadas en disco**: Todo se maneja en memoria mediante objetos `SecureString` y `PSCredential`. Las credenciales se conservan **solo mientras el script esté abierto** (se reutilizan entre conexiones) y se descartan con `c` o al cerrar el script.
- **Una misma cuenta para varios equipos**: Al reutilizar las credenciales, cada IP nueva recibe la misma cuenta. Usa una cuenta con los permisos mínimos necesarios, no tu cuenta de administrador principal.
- **Validaciones cruzadas**: Soporta verificación de MAC y Hostname para mitigar conexiones erróneas si la IP (lease DHCP) fue reasignada a otro equipo. Aplican a la primera conexión, la que se indica por parámetros.
- **Lanzador .bat**: aplica `ExecutionPolicy Bypass` únicamente al proceso que ejecuta el script y pide UAC para elevarse; no modifica la política de ejecución del equipo.
- **Autenticación NTLM**: La conexión directa por IP fuerza el uso de NTLM. Como el servidor remoto no se autentica ante ti de forma nativa (como sí lo haría Kerberos), `TrustedHosts` solo contiene la IP durante la conexión.
- **TrustedHosts se limpia solo**: El script agrega la IP únicamente mientras dura la sesión y la retira al terminar, sin tocar el comodín `*` ni las demás entradas. Si la ventana de PowerShell se cierra de golpe o el equipo se apaga durante la sesión, la limpieza podría no ejecutarse: en ese caso revisa [Cómo revertir los cambios](#cómo-revertir-los-cambios).

---

## Limitaciones conocidas

- Solo acepta **IPv4**, no nombres de host ni IPv6.
- Usa HTTP (5985); no contempla HTTPS (5986).
- El prompt remoto es propio, no `Enter-PSSession`: un comando por línea, sin autocompletado con Tab y sin programas interactivos.
- `-MacAddress` y `-ExpectedHostName` solo aplican a la primera conexión del script.
- La verificación de MAC solo funciona si el equipo está en la misma subred.
- La prueba de puertos espera como máximo 2 segundos; en un enlace muy lento podría dar un falso "no alcanzable". En ese caso responde `s` a `¿Intentar conectar de todos modos?`.
- Si el proceso se interrumpe de forma abrupta (cierre forzado de la ventana, apagón), la IP puede quedar en `TrustedHosts` y habría que retirarla manualmente.

---

## Cómo revertir los cambios

Normalmente el script retira la IP por sí solo. Si apareció la advertencia de que no pudo hacerlo, o si cerraste la ventana de golpe durante una sesión, puedes limpiar la IP manualmente:

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

| Antes (`Enter-PSSession`) | Ahora |
|---------------------------|-------|
| Una IP por ejecución; al salir del remoto quedabas en la consola local | **Bucle**: al salir del remoto vuelve a pedir una IP. Para terminar se escribe `salir` y se confirma |
| `Exit-PSSession` cerraba sin confirmación | `exit`, `salir`, `quit` y `Exit-PSSession` piden confirmación `[S/n]`; salir del script también |
| El script terminaba con `Enter-PSSession` como última línea | **Prompt remoto propio** sobre la misma sesión (un comando por línea, sin Tab ni programas interactivos) |
| Limpieza **manual**: copiar el comando cyan para `TrustedHosts` y ejecutar `Remove-PSSession -Id` | **Limpieza automática** al salir: cierra la sesión y retira la IP de `TrustedHosts` (también ante errores o `Ctrl+C`) |
| Dominio, usuario y contraseña se pedían en cada ejecución | Se piden **una sola vez** y se reutilizan hasta cerrar el script; `c` los descarta |
| Una IP inválida o vacía terminaba el script | Vuelve a preguntar. Solo un `-MacAddress` inválido pasado por parámetro termina el script (código 1) |
| `-MacAddress` y `-ExpectedHostName` aplicaban a la única conexión | Aplican solo a la primera conexión |
| Ante un equipo inalcanzable, esperaba el timeout de DCOM (hasta 20 s) y los reintentos de WinRM | Prueba los puertos 5985 y 135 **antes de pedir credenciales**: omite el inicio remoto si WinRM ya responde y, si ninguno responde, avisa y pregunta antes de continuar |
| El lanzador `.bat` mantenía la consola abierta con `-NoExit` | Cierra la ventana al terminar y solo hace una pausa si el script termina con error |
| El README no mencionaba el lanzador | Se documenta `configure-remote.bat`: elevación automática, `ExecutionPolicy Bypass` solo para el proceso y paso de argumentos al script |
| La documentación decía que WinRM quedaba en inicio automático | Corrección de la documentación: por defecto solo se **inicia** el servicio; el inicio automático requiere `-EnableAutoStart` |

### Historial de versiones anteriores

| Antes | Ahora |
|-------|-------|
| Contraseña y usuario fijos en el código | Se piden dominio, usuario y contraseña oculta (o se usa `-Credential`) |
| Activación remota usando `sc.exe` | Activación remota moderna utilizando **CIM (DCOM)** con las credenciales provistas |
| Limpieza automática de TrustedHosts | Comando de limpieza generado manualmente para evitar el error `0x8009030e` (reemplazado: la versión actual vuelve a limpiar automáticamente, pero después de cerrar la sesión) |
| Sin verificación de identidad | Soporte opcional de verificación cruzada mediante `-MacAddress` y `-ExpectedHostName` |
| Sin advertencia de limpieza | El script indicaba los comandos exactos de limpieza (`Set-Item` y `Remove-PSSession`) antes de abrir la consola (ya no es necesario) |
