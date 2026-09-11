# autobackup.sh

Backup incremental y automático a un disco externo por etiqueta.
Enchufas el disco, ejecutas el script, listo.

Sin TUI, sin archivo de config, sin wizard. Todo se configura editando
las variables al inicio del script.

---

## Requisitos

- **Arch Linux** (o cualquier distro con las mismas herramientas).
- Paquetes:
  ```bash
  sudo pacman -S rsync util-linux udisks2
  ```
  - `rsync` — la copia en sí.
  - `blkid`, `findmnt` — vienen con `util-linux` (detección de disco).
  - `udisksctl` — viene con `udisks2` (montaje sin sudo).

- Un disco externo formateado con **btrfs**, **ext4**, etc., y con una
  **etiqueta** asignada. Verifica con:
  ```bash
  lsblk -o NAME,LABEL,UUID,FSTYPE
  ```

- Un agente Polkit corriendo en tu sesión (lo normal en cualquier
  escritorio). Si usas un WM minimal, mira la sección *Polkit* más abajo.

---

## Uso

```bash
chmod +x autobackup.sh

./autobackup.sh                 # backup real
./autobackup.sh --dry-run       # simula, no escribe nada
./autobackup.sh --keep-mount    # no desmonta el disco al terminar
./autobackup.sh --help          # ayuda
```

Flujo normal:

1. Enchufas el disco externo.
2. Ejecutas `./autobackup.sh`.
3. El script detecta el disco, lo monta, copia, rota snapshots viejos
   y lo desmonta.
4. Puedes desconectar el disco sin más.

Si el disco **no está conectado**, el script sale con código 0 y un
mensaje. Pensado para poder colgarlo de cron/systemd sin que se queje.

---

## Configuración

Todo se edita en la sección `CONFIG` al inicio del script:

```bash
LABEL="backup"                       # etiqueta del disco (blkid -L)

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

SOURCES=(
    "$REAL_HOME/Pictures"
    "$REAL_HOME/Documents"
)

EXCLUDES=(
    ".cache"
    "node_modules"
    ".local/share/Trash"
)

KEEP=5                               # snapshots a retener
KEEP_MOUNT=0                         # 1 = no desmontar al terminar
```

### Variables

| Variable      | Qué hace                                                     |
|---------------|--------------------------------------------------------------|
| `LABEL`       | Etiqueta del disco. Debe coincidir exactamente (minúsculas incluidas). |
| `SOURCES`     | Array de rutas a respaldar.                                   |
| `EXCLUDES`    | Array de patrones a excluir. Se pasan a `rsync --exclude`.    |
| `KEEP`        | Cuántos snapshots conservar. Los más viejos se borran.        |
| `KEEP_MOUNT`  | Si es `1`, no desmonta al terminar.                           |

### Sobre `REAL_USER` / `REAL_HOME`

El script usa `$SUDO_USER` cuando se ejecuta con `sudo`, para que
`$REAL_HOME` apunte a tu home real y no a `/root`. Si lo ejecutas como
usuario normal, cae a `$USER`.

Esto evita dos problemas clásicos:
- Hardcodear `/home/tuusuario` (se rompe si cambias de usuario).
- Usar `~` dentro de comillas (bash no lo expande).

---

## Estructura en el disco

```
/run/media/<usuario>/backup/
└── backups/
    └── <hostname>/
        ├── 2026-09-11_143838/
        ├── 2026-09-12_093012/
        └── 2026-09-13_081544/
```

- Cada ejecución crea una carpeta con timestamp `YYYY-MM-DD_HHMMSS`.
- Los archivos **no modificados** se enlazan duro (`--link-dest`) al
  snapshot anterior, así que sólo los nuevos ocupan espacio real.
- Los snapshots antiguos se borran cuando superan `KEEP`.

Efecto: espacio total ≈ tamaño de una copia completa + cambios
acumulados. Como Time Machine, pero a lo bruto.

---

## Cómo funciona por dentro

1. **`blkid -L "$LABEL"`** → encuentra el device por etiqueta.
2. **`findmnt`** → comprueba si ya está montado.
3. **`udisksctl mount`** → lo monta sin sudo en `/run/media/$USER/`.
4. **`rsync -aAXH --numeric-ids --delete --link-dest=...`** → copia
   incremental preservando permisos, ACLs, xattrs y hardlinks.
5. **`find ... | sort -r | tail -n +$((KEEP+1))`** → rota snapshots
   viejos.
6. **`udisksctl unmount`** → desmonta limpio.

---

## Ejecución automática

### Opción A — `systemd` + `udev` (plug and play real)

Cuando enchufas el disco, systemd lo monta y lanza el backup.

**1. Crea `/usr/local/bin/mount-backup.sh`:**
```bash
#!/usr/bin/env bash
set -euo pipefail
DEV="$(blkid -L backup)" || exit 0
MOUNT="/mnt/backup"
findmnt -rno TARGET "$DEV" >/dev/null && exit 0
mkdir -p "$MOUNT"
mount "$DEV" "$MOUNT"
```

**2. Crea `/etc/systemd/system/usb-backup@.service`:**
```ini
[Unit]
Description=Monta backup y lanza autobackup
After=dev-%i.device
BindsTo=dev-%i.device

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mount-backup.sh
ExecStartPost=/home/dantalion/autobackup.sh
ExecStop=/bin/umount /mnt/backup

[Install]
WantedBy=multi-user.target
```

**3. Crea `/etc/udev/rules.d/99-backup.rules`:**
```
ACTION=="add", ENV{ID_FS_LABEL}=="backup", ENV{SYSTEMD_WANTS}+="usb-backup@%k.service"
```

**4. Recarga:**
```bash
sudo systemctl daemon-reload
sudo udevadm control --reload-rules
```

> ⚠️ No pongas `mount` dentro de una regla udev directamente. Desde
> systemd 212, udev corre en un namespace de montaje privado y el
> montaje no se propaga al resto del sistema. Por eso se lanza un
> servicio systemd.

### Opción B — `cron`

```cron
@reboot /home/dantalion/autobackup.sh
0 */6 * * * /home/dantalion/autobackup.sh
```

Solo funciona si el disco está montado (o si `udisksctl` puede montarlo
desde cron, que no siempre es el caso sin sesión gráfica).

### Opción C — manual

Enchufar, ejecutar, desenchufar. Sin magia.

---

## Logs

No hay logs separados. El script imprime a stdout/stderr con timestamps:

```
[2026-09-11 14:38:38] Disco detectado: /dev/sda1
[2026-09-11 14:38:40] Montando /dev/sda1 con udisksctl...
[2026-09-11 14:38:41] Montado en /run/media/dantalion/backup
[2026-09-11 14:38:41] Origen : /home/dantalion/Pictures /home/dantalion/Documents
[2026-09-11 14:38:41] Destino: /run/media/dantalion/backup/backups/serufu/2026-09-11_143838
[2026-09-11 14:38:41] Primer snapshot (completo)
[2026-09-11 14:38:41] → /home/dantalion/Pictures
[2026-09-11 15:12:03] → /home/dantalion/Documents
[2026-09-11 15:13:47] Backup OK: /run/media/dantalion/backup/backups/serufu/2026-09-11_143838
[2026-09-11 15:13:47] Desmontando /run/media/dantalion/backup
[2026-09-11 15:13:48] Listo.
```

Para guardarlo a archivo:
```bash
./autobackup.sh 2>&1 | tee backup.log
```

O si lo corres desde systemd, `journalctl -u usb-backup@*.service`.

---

## Restaurar

Este script **no restaura**. Es intencional — restaurar con `rsync
--delete` desde un script automático es una forma estupenda de
destrozar tu sistema por un error tonto.

Para restaurar, hazlo a mano:

```bash
# Ver snapshots disponibles
ls /run/media/$USER/backup/backups/serufu/

# Restaurar una carpeta concreta
rsync -aAXH --numeric-ids \
    /run/media/$USER/backup/backups/serufu/2026-09-11_143838/Pictures/ \
    ~/Pictures/

# O montar el snapshot y copiar con tu file manager
```

> 💡 Truco: los snapshots son carpetas normales. Puedes navegarlas con
> `ls`, `cp`, `rsync`, `ranger`, `nautilus`… lo que sea. No necesitas
> ninguna herramienta especial.

---

## Problemas comunes

### `blkid -L backup` no devuelve nada

- El disco no está conectado.
- La etiqueta está en mayúsculas distintas (`Backup` vs `backup`).
  `blkid -L` distingue mayúsculas.
- El disco nunca se etiquetó. Asígnale etiqueta:
  ```bash
  sudo btrfs filesystem label /dev/sdXN backup   # btrfs
  sudo e2label /dev/sdXN backup                  # ext4
  ```

### `udisksctl mount` cuelga o falla con "Not authorized"

Falta un agente Polkit. Instala el de tu DE:
- GNOME: `sudo pacman -S polkit-gnome`
- KDE: ya viene con Plasma
- Hyprland/Sway: `sudo pacman -S hyprpolkitagent` o `lxqt-policykit`

Alternativa (sin agente), regla Polkit en
`/etc/polkit-1/rules.d/50-udisks2.rules`:
```javascript
polkit.addRule(function(action, subject) {
    if (action.id.startsWith("org.freedesktop.udisks2.") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
```
Luego: `sudo systemctl restart polkit`.

### `mkdir: cannot create directory '/mnt/backup': Permission denied`

Estás mezclando `mount` clásico con `udisksctl`. Con `udisksctl` el
script **no necesita `/mnt`** — monta en `/run/media/$USER/`. Si viste
ese error, era una versión anterior del script.

### El script se queda mudo tras "Disco detectado"

Clásico de `set -euo pipefail` + un pipe donde un comando sale con
código ≠ 0 sin imprimir nada. La línea culpable suele ser:

```bash
MOUNT="$(findmnt -rno TARGET "$DEV" 2>/dev/null | head -n1)"
```

Si `findmnt` no encuentra nada, sale con 1, y `pipefail` propaga ese
fallo. Solución: `|| true` al final.

### `rsync` con `--link-dest` no ahorra espacio

- Verifica que origen y destino estén en el **mismo sistema de
  archivos** (deben estarlo, ambos en el disco externo).
- Verifica que el filesystem soporte hardlinks (btrfs, ext4, xfs: sí;
  exfat, vfat: **no** — por eso este script asume un formato Unix).

### El progreso `--info=progress2` no se ve

Solo se muestra si hay TTY. En cron/systemd no aparece (y está bien,
no ensucia los logs).

---

## Notas de diseño

- **Sin archivo de config externo.** Todo vive en el script. Copiar el
  script a otra máquina = copiar la config.
- **Sin TUI.** No depende de `dialog` ni de terminal interactiva.
  Funciona en cron, systemd, udev, o a mano.
- **Sin restauración.** Ver arriba.
- **Detección por etiqueta, no por device.** El disco puede ser `sda1`
  hoy y `sdb1` mañana; la etiqueta es estable.
- **Salida limpia si no hay disco.** Código 0, mensaje informativo,
  nada más. Colgable de cualquier automatización.

---

## Licencia

Haz lo que quieras con él. Es tu script.

