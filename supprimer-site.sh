#!/bin/bash
# =============================================================================
# supprimer-site.sh — Suppression complète d'un site client du VPN GTB/GTC
# Usage : sudo supprimer-site.sh
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
step()    { echo -e "${CYAN}[....] $1${NC}"; }
success() { echo -e "${GREEN}[ OK ] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
error()   { echo -e "${RED}[FAIL] $1${NC}"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}";
            echo -e "${BOLD}${CYAN}  $1${NC}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

[ "$EUID" -ne 0 ] && error "Lancer avec sudo : sudo supprimer-site.sh"

OVPN_CA="$(find /home -maxdepth 2 -name "openvpn-ca" -type d 2>/dev/null | head -1)"
[ -z "$OVPN_CA" ] && OVPN_CA="/root/openvpn-ca"
[ ! -d "$OVPN_CA" ] && error "PKI introuvable."

SITES_CSV="/etc/openvpn/sites.csv"
CCD_DIR="/etc/openvpn/ccd"
SCRIPTS_DIR="/etc/openvpn/scripts"
ADMIN_HOME="$(dirname "$OVPN_CA")"
REAL_USER="$(stat -c '%U' "$OVPN_CA")"

header "Suppression d'un site VPN"

# ── Lister les sites disponibles ──────────────────────────────────────────────
echo -e "${BOLD}Sites configurés :${NC}"
echo ""

SITES=()
INDEX=0

while IFS=',' read -r site vpn_net vpn_mask phys_net phys_mask; do
    [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
    INDEX=$((INDEX + 1))
    SITES+=("$site")
    VPN_PC=$(echo "$vpn_net" | sed 's/\.0$/.1/')
    echo -e "  ${CYAN}[$INDEX]${NC} ${BOLD}$site${NC}"
    echo -e "        VPN : ${YELLOW}$vpn_net/$vpn_mask${NC}  →  Physique : ${YELLOW}$phys_net/$phys_mask${NC}  (mini-PC: $VPN_PC)"
done < "$SITES_CSV"

if [ ${#SITES[@]} -eq 0 ]; then
    warn "Aucun site configuré dans sites.csv."
    exit 0
fi

echo ""
echo -e "  ${RED}[0]${NC} Annuler"
echo ""

# ── Sélection ────────────────────────────────────────────────────────────────
while true; do
    read -p "Numéro du site à supprimer : " CHOICE
    [ "$CHOICE" = "0" ] && echo "Annulé." && exit 0
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#SITES[@]}" ]; then
        TARGET="${SITES[$((CHOICE - 1))]}"
        break
    fi
    warn "Saisir un numéro entre 0 et ${#SITES[@]}"
done

# Récupérer les infos du site depuis sites.csv
SITE_LINE=$(grep "^${TARGET}," "$SITES_CSV")
VPN_NET=$(echo "$SITE_LINE" | cut -d',' -f2)
VPN_MASK=$(echo "$SITE_LINE" | cut -d',' -f3)
PHYS_NET=$(echo "$SITE_LINE" | cut -d',' -f4)

# ── Confirmation avec avertissement fort ─────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ATTENTION — ACTION IRRÉVERSIBLE               ║${NC}"
echo -e "${RED}${BOLD}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Site ciblé : ${YELLOW}${BOLD}$TARGET${NC}"
echo -e "  Réseau VPN : ${YELLOW}$VPN_NET/$VPN_MASK${NC}"
echo -e "  Réseau physique : ${YELLOW}$PHYS_NET${NC}"
echo ""
echo -e "  Ce qui va être supprimé :"
echo -e "    • Certificat révoqué dans la PKI"
echo -e "    • Fichier CCD : $CCD_DIR/$TARGET"
echo -e "    • Ligne dans sites.csv"
echo -e "    • Route dans server.conf"
echo -e "    • Règles iptables associées"
echo -e "    • Fichier .ovpn : $ADMIN_HOME/$TARGET.ovpn (si présent)"
echo -e "    • CCD de tous les techniciens mis à jour (route supprimée)"
echo -e "    • La connexion active du site sera coupée immédiatement"
echo ""
echo -e "  ${RED}Cette action ne peut pas être annulée.${NC}"
echo ""
read -p "Taper le nom exact du site pour confirmer : " CONFIRM_NAME

if [ "$CONFIRM_NAME" != "$TARGET" ]; then
    warn "Nom incorrect — opération annulée."
    exit 1
fi

echo ""
echo -e "${BOLD}${CYAN}═══ Suppression de $TARGET ═══${NC}"
echo ""

# ── Révocation du certificat ──────────────────────────────────────────────────
if [ -f "$OVPN_CA/pki/issued/$TARGET.crt" ]; then
    step "Révocation du certificat dans la PKI..."
    echo "yes" | sudo -u "$REAL_USER" \
        bash -c "cd $OVPN_CA && ./easyrsa revoke $TARGET" \
        > /dev/null 2>&1
    success "Certificat révoqué"
else
    warn "Certificat $TARGET.crt introuvable — peut avoir été déjà supprimé"
fi

# ── Regénération de la CRL ────────────────────────────────────────────────────
step "Regénération de la CRL..."
sudo -u "$REAL_USER" \
    bash -c "cd $OVPN_CA && ./easyrsa gen-crl" \
    > /dev/null 2>&1
cp "$OVPN_CA/pki/crl.pem" /etc/openvpn/crl.pem
chmod 644 /etc/openvpn/crl.pem
success "CRL mise à jour — connexion du site refusée immédiatement"

# ── Suppression du fichier CCD ────────────────────────────────────────────────
if [ -f "$CCD_DIR/$TARGET" ]; then
    step "Suppression du fichier CCD..."
    rm -f "$CCD_DIR/$TARGET"
    success "Fichier CCD supprimé : $CCD_DIR/$TARGET"
else
    warn "Fichier CCD introuvable — ignoré"
fi

# ── Suppression du .ovpn ──────────────────────────────────────────────────────
if [ -f "$ADMIN_HOME/$TARGET.ovpn" ]; then
    step "Suppression du fichier .ovpn..."
    rm -f "$ADMIN_HOME/$TARGET.ovpn"
    success "Fichier .ovpn supprimé"
else
    info "Fichier .ovpn non trouvé (transmis au client) — ignoré"
fi

# ── Nettoyage PKI ─────────────────────────────────────────────────────────────
step "Nettoyage des fichiers PKI..."
for f in \
    "$OVPN_CA/pki/private/$TARGET.key" \
    "$OVPN_CA/pki/issued/$TARGET.crt" \
    "$OVPN_CA/pki/reqs/$TARGET.req"; do
    [ -f "$f" ] && rm -f "$f" && success "  Supprimé : $(basename $f)"
done

# ── Suppression de la ligne dans sites.csv ────────────────────────────────────
step "Suppression de l'entrée dans sites.csv..."
TMPFILE=$(mktemp)
grep -v "^${TARGET}," "$SITES_CSV" > "$TMPFILE" || true
mv "$TMPFILE" "$SITES_CSV"
success "Ligne supprimée de sites.csv"

# ── Suppression de la route dans server.conf ─────────────────────────────────
step "Suppression de la route dans server.conf..."
TMPFILE=$(mktemp)
grep -v "route $VPN_NET $VPN_MASK" /etc/openvpn/server.conf > "$TMPFILE" || true
mv "$TMPFILE" /etc/openvpn/server.conf
success "Route supprimée de server.conf"

# ── Suppression des règles iptables ──────────────────────────────────────────
step "Suppression des règles iptables associées à $TARGET..."
REMOVED=0

# Lister toutes les règles FORWARD avec le commentaire du site
while true; do
    # Chercher une règle avec le commentaire du site
    LINE=$(iptables -L FORWARD --line-numbers -n 2>/dev/null | \
           grep -E "$TARGET" | head -1 | awk '{print $1}')
    [ -z "$LINE" ] && break
    iptables -D FORWARD "$LINE" 2>/dev/null && REMOVED=$((REMOVED + 1)) || break
done

if [ "$REMOVED" -gt 0 ]; then
    success "$REMOVED règle(s) iptables supprimée(s)"
else
    warn "Aucune règle iptables trouvée pour $TARGET (peut-être déjà absentes)"
fi

netfilter-persistent save > /dev/null 2>&1
success "Règles iptables sauvegardées"

# ── Mise à jour des CCD techniciens ──────────────────────────────────────────
TECH_COUNT=$(ls "$CCD_DIR"/tech-* 2>/dev/null | wc -l)
if [ "$TECH_COUNT" -gt 0 ]; then
    step "Mise à jour des CCD de $TECH_COUNT technicien(s) — suppression de la route $TARGET..."
    "$SCRIPTS_DIR/update-tech-ccd.sh"
    success "CCD techniciens mis à jour — $TARGET retiré de leurs accès"
else
    info "Aucun technicien existant — rien à mettre à jour"
fi

# ── Redémarrage OpenVPN ───────────────────────────────────────────────────────
step "Redémarrage du service OpenVPN..."
systemctl restart openvpn@server
sleep 2
if systemctl is-active --quiet openvpn@server; then
    success "Service redémarré"
else
    warn "Service instable — vérifier : sudo journalctl -xeu openvpn@server"
fi

# ── Résumé final ──────────────────────────────────────────────────────────────
header "Site $TARGET supprimé ✓"

echo -e "${GREEN}${BOLD}✓ Site '$TARGET' entièrement supprimé du VPN${NC}"
echo ""
echo -e "  • Certificat révoqué — connexion refusée immédiatement"
echo -e "  • Route $VPN_NET/$VPN_MASK retirée du serveur"
echo -e "  • Règles iptables nettoyées"
echo -e "  • Techniciens mis à jour — $TARGET n'apparaît plus dans leurs accès"
echo ""
echo -e "${BOLD}À faire côté site :${NC}"
echo -e "  Éteindre ou reconfigurer le mini-PC du site pour éviter"
echo -e "  des tentatives de reconnexion répétées dans les logs."
echo ""
echo -e "${BOLD}Vérification :${NC}"
echo -e "  ${CYAN}grep '$TARGET' /etc/openvpn/sites.csv${NC}       — doit retourner vide"
echo -e "  ${CYAN}grep '$TARGET' /etc/openvpn/server.conf${NC}     — doit retourner vide"
echo -e "  ${CYAN}sudo cat /var/log/openvpn-status.log${NC}        — $TARGET absent"
echo ""
