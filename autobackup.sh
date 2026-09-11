#!/usr/bin/env bash
# autobackup.sh — enchufa el disco, ejecuta el script, listo.
# Monta (sin sudo, vía udisksctl), copia, rota y desmonta.
#
# Uso: ./autobackup.sh [--dry-run] [--keep-mount] [--help]

set -euo pipefail

#===================== CONFIG =====================
LABEL="backup"                       # etiqueta del disco (blkid -L)

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

SOURCES=(
    "$REAL_HOME/Pictures"
    "$REAL_HOME/Documents"
)

EXCLUDES=(                           # qué NO respaldar
    ".cache"
    "node_modules"
    ".local/share/Trash"
)
KEEP=5                               # snapshots a retener
KEEP_MOUNT=0                         # 1 = no desmontar al terminar
#==================================================

DRY_RUN=0
HOST="$(cat /proc/sys/kernel/hostname 2>/dev/null || uname -n)"
HOST="${HOST%%.*}"
STAMP="$(date +%Y-%m-%d_%H%M%S)"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=1 ;;
        --keep-mount) KEEP_MOUNT=1 ;;
        --help|-h)    usage ;;
        *) die "Argumento desconocido: $arg" ;;
    esac
done

#--- deps ---
for c in rsync blkid findmnt udisksctl; do
    command -v "$c" >/dev/null || die "falta '$c' (pacman -S rsync util-linux udisks2)"
done

#--- ¿disco conectado? ---
DEV="$(blkid -L "$LABEL" 2>/dev/null || true)"
if [[ -z "$DEV" ]]; then
    log "Disco '$LABEL' no conectado. Nada que hacer."
    exit 0
fi
log "Disco detectado: $DEV"

#--- ¿ya montado? si no, montar con udisksctl ---
MOUNT="$(findmnt -rno TARGET "$DEV" 2>/dev/null | head -n1)"
if [[ -z "$MOUNT" ]]; then
    if (( DRY_RUN )); then
        log "DRY-RUN: montaría $DEV con udisksctl"
        # Para simular el resto necesitamos una ruta; usamos la esperada.
        MOUNT="/run/media/$USER/$LABEL"
    else
        log "Montando $DEV con udisksctl..."
        udisksctl mount -b "$DEV" --no-user-interaction >/dev/null \
            || die "udisksctl no pudo montar $DEV (¿sesión Polkit activa?)"
        MOUNT="$(findmnt -rno TARGET "$DEV" | head -n1)"
        [[ -n "$MOUNT" ]] || die "montaje reportado OK pero no encuentro el punto de montaje"
        log "Montado en $MOUNT"
    fi
else
    log "Ya estaba montado en $MOUNT"
fi

BASE="$MOUNT/backups/$HOST"
DEST="$BASE/$STAMP"

#--- exclude args ---
EXC=()
for e in "${EXCLUDES[@]}"; do EXC+=(--exclude="$e"); done

#--- link-dest contra el último snapshot ---
mkdir -p "$BASE"
LATEST="$(find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n1)"
LINK=()
[[ -n "$LATEST" ]] && LINK=(--link-dest="$BASE/$LATEST")

log "Origen : ${SOURCES[*]}"
log "Destino: $DEST"
[[ -n "$LATEST" ]] && log "Base incremental: $LATEST" || log "Primer snapshot (completo)"

#--- copiar ---
mkdir -p "$DEST"
RC=0
for src in "${SOURCES[@]}"; do
    [[ -e "$src" ]] || { log "WARN: no existe $src, salto"; continue; }
    log "→ $src"
    rsync -aAXH --numeric-ids --delete --info=progress2 \
       "${EXC[@]}" "${LINK[@]}" \
       "$src" "$DEST/" || RC=$?
done

if (( RC != 0 )); then
    log "Backup terminó con errores (rc=$RC)"
else
    log "Backup OK: $DEST"
fi

#--- rotación ---
if (( ! DRY_RUN )); then
    mapfile -t OLD < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tail -n +$((KEEP + 1)))
    for snap in "${OLD[@]}"; do
        log "Rotando: $snap"
        rm -rf -- "${BASE:?}/$snap"
    done
fi

#--- desmontar (salvo --keep-mount o dry-run) ---
if (( ! DRY_RUN && ! KEEP_MOUNT )); then
    log "Desmontando $MOUNT"
    udisksctl unmount -b "$DEV" --no-user-interaction >/dev/null \
        || log "WARN: no pude desmontar (¿algo lo está usando?)"
fi

log "Listo."
exit "$RC"
