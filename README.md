# DebInstaller

App iOS mini para instalar paquetes `.deb` directo en jailbreak Dopamine, sin depender de Sileo/Zebra/SSH/iDownload.

## Qué hace

- UI con 3 formas de obtener un `.deb`:
  - Picker desde Archivos / iCloud / AirDrop
  - Instalar paquete `.deb` **embebido** en el bundle de la app
  - Bajar `.deb` desde URL arbitraria
- Ejecuta `dpkg -i` usando los binarios del jailbreak Dopamine en `/var/jb/usr/bin/`
- Muestra stdout + stderr + exit code en pantalla

## Cómo compila

Push a `main` → GitHub Actions compila `.ipa` sin firmar → bajas de Artifacts → instalas vía sideloadly o `ideviceinstaller -i`.

## Cómo instala tweaks

1. Sideloadly la .ipa (o `ideviceinstaller -i DebInstaller-unsigned.ipa -u <UDID>`)
2. Abrir DebInstaller en el iPad
3. Tocar "Instalar paquete embebido" o "Elegir .deb"
4. Esperar — muestra el log
5. Si OK, respring desde Dopamine → tweak activo

## Nota técnica

Requiere Dopamine (rootless) activo porque usa `dpkg` de `/var/jb/`. La app corre sideloaded pero `posix_spawn` hereda el contexto del `systemhook` inyectado por Dopamine, lo que permite escribir en el jbroot.
