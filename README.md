# ambxst — mi configuración

Configuración y parches propios sobre [ambxst](https://github.com/Ambxst/Ambxst),
un shell de escritorio en QML/Quickshell para Hyprland. Esto es lo que se ve en
["El notch"](#) — un panel que baja del borde superior con widgets, fondos,
sistema, monitores y proyección.

No es un fork de ambxst: son los archivos que personalizan una instalación ya
existente. Pensado para correr sobre Hyprland sí o sí.

## Qué hay aquí

| Carpeta | Qué es |
|---|---|
| `config/` | Configuración en vivo de ambxst — binds, tema, sistema, clima, cada tab del dashboard. Va en `~/.config/ambxst/`. |
| `patches/` | Parches sobre el QML/Python fuente de ambxst — no son configuración, modifican su código. |
| `systemd/` | `ambxst.service`, unidad de usuario que mantiene el shell corriendo. |

### Los parches, uno por uno

- **`lockscreen-custom.patch`** — rediseño de la pantalla de bloqueo: hora en
  Roboto Light, fecha con tracking, pill de login sin avatar.
- **`ambxst-custom-tabs.patch`** + **`ambxst-tabs/`** — dos tabs nuevos en el
  dashboard: Monitores (edita `~/.config/hypr/monitors.conf` desde la UI) y
  Proyección (duplicar/extender/solo-uno para dos monitores).
- **`system-monitor-intel-gpu.patch`** — la métrica de iGPU Intel, que upstream
  no leía; sale de `/proc/*/fdinfo`.
- **`matugen-wallpaper.sh.custom`** — genera la paleta del sistema por color
  dominante del wallpaper (no por croma), y resuelve el fondo correcto cuando
  el wallpaper es un video.

Cada parche trae su `.orig` (el archivo de ambxst antes del cambio) junto al
`.custom` (el resultado) para que puedas diffearlos vos mismo o regenerar el
`.patch` si tu versión de ambxst ya no calza con el `.orig`.

## Instalar

Asume una instalación de ambxst ya funcionando ([instrucciones upstream](https://github.com/Ambxst/Ambxst)).

```bash
# 1. Configuración
cp -r config/* ~/.config/ambxst/

# 2. Parches — aplica sobre la fuente local de ambxst (ruta típica: ~/.local/src/ambxst)
cd ~/.local/src/ambxst
patch -p1 < /ruta/a/este/repo/patches/lockscreen-custom.patch
patch -p1 < /ruta/a/este/repo/patches/ambxst-custom-tabs.patch
patch -p1 < /ruta/a/este/repo/patches/system-monitor-intel-gpu.patch
cp /ruta/a/este/repo/patches/matugen-wallpaper.sh.custom ruta/al/script/matugen-wallpaper.sh

# 3. Servicio
cp systemd/ambxst.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ambxst.service
```

**Un `ambxst update` sobrescribe la fuente local y se lleva los parches con
él.** Hay que reaplicarlos después de cada actualización — por eso cada uno
trae su `.orig`: si upstream cambió ese archivo, el `patch` falla limpio en
vez de corromper algo a medias.

## Qué NO hace este repo

No instala Hyprland, Quickshell ni ambxst. No es un script de un comando. Es
el material de referencia para reproducir lo que sale en el video — leer antes
de copiar.

## Licencia

MIT. Usa lo que sirva, ignora lo que no.
