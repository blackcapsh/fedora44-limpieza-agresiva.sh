#!/usr/bin/env bash
# =============================================================================
# fedora44-limpieza-agresiva.sh
# Limpieza agresiva para Fedora 44: DNF, kernels, Podman, paquetes huérfanos
# Uso: sudo bash fedora44-limpieza-agresiva.sh
# =============================================================================

set -euo pipefail

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
BLU='\033[0;34m'; CYA='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo -e "${BLU}[INFO]${NC}  $*"; }
ok()   { echo -e "${GRN}[OK]${NC}    $*"; }
warn() { echo -e "${YEL}[WARN]${NC}  $*"; }
sec()  { echo -e "\n${BOLD}${CYA}══════════════════════════════════════════${NC}"; \
         echo -e "${BOLD}${CYA}  $*${NC}"; \
         echo -e "${BOLD}${CYA}══════════════════════════════════════════${NC}\n"; }

humanize() {
    local bytes=$1
    if   (( bytes >= 1073741824 )); then printf "%.1f GB" "$(echo "scale=1; $bytes/1073741824" | bc)"
    elif (( bytes >= 1048576    )); then printf "%.1f MB" "$(echo "scale=1; $bytes/1048576"    | bc)"
    elif (( bytes >= 1024       )); then printf "%.1f KB" "$(echo "scale=1; $bytes/1024"       | bc)"
    else printf "%d B" "$bytes"; fi
}

saved=0
add_saved() {
    local path="$1"
    [[ -e "$path" ]] && saved=$(( saved + $(du -sb "$path" 2>/dev/null | awk '{print $1}') ))
}

# ── Verificar root ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR]${NC} Ejecuta como root: sudo bash $0"; exit 1; }

echo -e "\n${BOLD}${RED}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${RED}║   LIMPIEZA AGRESIVA — FEDORA 44              ║${NC}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${NC}\n"
warn "Este script ELIMINA datos permanentemente."
warn "Asegúrate de tener un snapshot o backup antes de continuar."
echo
read -rp "$(echo -e "${YEL}¿Continuar? [s/N]:${NC} ")" CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && { echo "Abortado."; exit 0; }

# =============================================================================
# 1. CACHÉ Y METADATOS DE DNF
# =============================================================================
sec "1. Caché y metadatos de DNF"

log "Limpiando caché de DNF (all)..."
add_saved /var/cache/dnf
dnf clean all -q
ok "Caché de DNF eliminada."

log "Eliminando metadatos obsoletos..."
dnf makecache -q 2>/dev/null || true
ok "Metadatos regenerados."

# =============================================================================
# 2. KERNELS ANTIGUOS
# =============================================================================
sec "2. Kernels antiguos"

CURRENT_KERNEL=$(uname -r)
log "Kernel activo: ${BOLD}$CURRENT_KERNEL${NC}"

# Contar kernels instalados
KERNEL_COUNT=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | wc -l)
log "Kernels instalados: $KERNEL_COUNT"

if (( KERNEL_COUNT > 1 )); then
    log "Eliminando kernels viejos (conservando el activo)..."
    # Listar los que se van a eliminar
    dnf repoquery --installonly --latest-limit=-1 -q 2>/dev/null | \
        while read -r pkg; do warn "  → Eliminando: $pkg"; done

    dnf remove -y \
        $(dnf repoquery --installonly --latest-limit=-1 -q 2>/dev/null) \
        2>/dev/null || warn "No se encontraron kernels adicionales para eliminar."
    ok "Kernels antiguos eliminados."
else
    ok "Solo hay un kernel instalado. Nada que hacer."
fi

# Forzar conservar solo 2 kernels en adelante
log "Configurando installonly_limit=2 en dnf.conf..."
sed -i '/^installonly_limit=/d' /etc/dnf/dnf.conf
echo "installonly_limit=2" >> /etc/dnf/dnf.conf
ok "installonly_limit=2 configurado."

# =============================================================================
# 3. PAQUETES HUÉRFANOS Y NO USADOS
# =============================================================================
sec "3. Paquetes huérfanos y no usados"

log "Eliminando dependencias huérfanas (autoremove)..."
dnf autoremove -y -q
ok "Autoremove completado."

# dnf-utils provee package-cleanup
if command -v package-cleanup &>/dev/null; then
    log "Eliminando duplicados con package-cleanup..."
    package-cleanup --dupes -y 2>/dev/null || true
    package-cleanup --cleandupes -y 2>/dev/null || true
    ok "Duplicados eliminados."
else
    warn "package-cleanup no encontrado — instalando dnf-utils..."
    dnf install -y -q dnf-utils 2>/dev/null || true
fi

log "Eliminando paquetes leaves sin dependientes (rpmorphan si disponible)..."
if command -v rpmorphan &>/dev/null; then
    rpmorphan -y 2>/dev/null || true
else
    warn "rpmorphan no instalado — omitido."
fi

# =============================================================================
# 4. PODMAN — IMÁGENES SIN USO
# =============================================================================
sec "4. Podman — imágenes sin uso"

if command -v podman &>/dev/null; then

    # Detener contenedores parados/muertos
    STOPPED=$(podman ps -aq --filter status=exited --filter status=dead 2>/dev/null || true)
    if [[ -n "$STOPPED" ]]; then
        log "Eliminando contenedores detenidos/muertos..."
        echo "$STOPPED" | xargs podman rm -f 2>/dev/null && ok "Contenedores eliminados." || warn "Error al eliminar algunos contenedores."
    else
        ok "No hay contenedores detenidos."
    fi

    # Imágenes dangling (sin tag)
    DANGLING=$(podman images -q --filter dangling=true 2>/dev/null || true)
    if [[ -n "$DANGLING" ]]; then
        log "Eliminando imágenes dangling..."
        echo "$DANGLING" | xargs podman rmi -f 2>/dev/null && ok "Imágenes dangling eliminadas." || warn "Error al eliminar imágenes dangling."
    else
        ok "No hay imágenes dangling."
    fi

    # Imágenes no referenciadas por ningún contenedor
    log "Ejecutando podman image prune --all --force..."
    podman image prune --all --force 2>/dev/null && ok "Imágenes sin uso eliminadas." || warn "No se pudo limpiar imágenes (¿contenedores activos?)."

    # Limpiar builds incompletos
    log "Limpiando build cache de Podman..."
    podman system prune --all --force --volumes 2>/dev/null && ok "Build cache y datos huérfanos eliminados." \
        || warn "Error en system prune — puede haber contenedores corriendo."

else
    warn "Podman no está instalado — omitiendo sección."
fi

# =============================================================================
# 5. PODMAN — VOLÚMENES EN DESUSO
# =============================================================================
sec "5. Podman — volúmenes en desuso"

if command -v podman &>/dev/null; then
    VOLS=$(podman volume ls -q --filter dangling=true 2>/dev/null || true)
    if [[ -n "$VOLS" ]]; then
        log "Volúmenes dangling encontrados:"
        echo "$VOLS" | while read -r v; do warn "  → $v"; done
        echo "$VOLS" | xargs podman volume rm 2>/dev/null && ok "Volúmenes eliminados." || warn "No se pudieron eliminar todos los volúmenes."
    else
        ok "No hay volúmenes huérfanos."
    fi
else
    warn "Podman no instalado — omitiendo."
fi

# =============================================================================
# 6. PODMAN — REDES SIN USO
# =============================================================================
sec "6. Podman — redes sin uso"

if command -v podman &>/dev/null; then
    log "Eliminando redes de Podman no usadas..."
    podman network prune --force 2>/dev/null && ok "Redes sin uso eliminadas." || warn "No se pudieron eliminar redes."
fi

# =============================================================================
# 7. JOURNALS DE SYSTEMD
# =============================================================================
sec "7. Journals de systemd"

JOURNAL_BEFORE=$(journalctl --disk-usage 2>/dev/null | awk '{print $7, $8}' || echo "N/A")
log "Uso actual de journals: $JOURNAL_BEFORE"
log "Conservando solo los últimos 7 días y máximo 200M..."
journalctl --vacuum-time=7d --vacuum-size=200M -q
ok "Journals compactados."

# =============================================================================
# 8. CACHÉ DE USUARIO (flatpak, pip, npm, yarn, cargo)
# =============================================================================
sec "8. Cachés de usuario y herramientas"

# Flatpak
if command -v flatpak &>/dev/null; then
    log "Eliminando Flatpaks no usados..."
    flatpak uninstall --unused -y 2>/dev/null && ok "Flatpaks huérfanos eliminados." || warn "Nada que eliminar en Flatpak."
    log "Limpiando caché de Flatpak..."
    rm -rf /var/tmp/flatpak-cache-* 2>/dev/null || true
fi

# pip (todos los usuarios)
if command -v pip3 &>/dev/null || command -v pip &>/dev/null; then
    log "Limpiando caché de pip..."
    PIP_CMD=$(command -v pip3 || command -v pip)
    $PIP_CMD cache purge 2>/dev/null && ok "Caché pip eliminada." || true
fi

# npm
if command -v npm &>/dev/null; then
    log "Limpiando caché de npm..."
    npm cache clean --force -q 2>/dev/null && ok "Caché npm eliminada." || true
fi

# yarn
if command -v yarn &>/dev/null; then
    log "Limpiando caché de yarn..."
    yarn cache clean 2>/dev/null && ok "Caché yarn eliminada." || true
fi

# cargo
if command -v cargo &>/dev/null; then
    log "Limpiando caché de Cargo (Rust)..."
    rm -rf ~/.cargo/registry/cache/ 2>/dev/null || true
    ok "Caché Cargo eliminada."
fi

# =============================================================================
# 9. ARCHIVOS TEMPORALES DEL SISTEMA
# =============================================================================
sec "9. Archivos temporales del sistema"

log "Limpiando /tmp y /var/tmp (archivos > 7 días)..."
find /tmp    -mindepth 1 -maxdepth 1 -atime +7 -exec rm -rf {} + 2>/dev/null || true
find /var/tmp -mindepth 1 -maxdepth 1 -atime +7 -exec rm -rf {} + 2>/dev/null || true
ok "/tmp y /var/tmp limpiados."

log "Limpiando cores de aplicaciones..."
find /var/lib/systemd/coredump/ -mindepth 1 -delete 2>/dev/null || true
ok "Coredumps eliminados."

# =============================================================================
# 10. RESUMEN FINAL
# =============================================================================
sec "Resumen final"

echo -e "${BOLD}Espacio libre actual:${NC}"
df -h / /home 2>/dev/null | tail -n +1

echo
echo -e "${BOLD}Top 10 directorios más pesados en /:${NC}"
du -shx --exclude=/proc --exclude=/sys --exclude=/dev \
   /var /usr /home /opt /tmp 2>/dev/null | sort -rh | head -10

echo
echo -e "${GRN}${BOLD}✔  Limpieza agresiva completada en Fedora 44.${NC}"
echo -e "${YEL}  Recomendado: reiniciar el sistema para liberar módulos del kernel antiguo.${NC}\n"
