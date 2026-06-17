#!/bin/bash
# =============================================================================
# revoquer-utilisateur.sh — Révocation et suppression complète d'un utilisateur
# Usage : sudo revoquer-utilisateur.sh
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

[ "$EUID" -ne 0 ] && error "Lancer avec sudo : sudo revoquer-utilisateur.sh"

OVPN_CA="$(find /home -maxdepth 2 -name "openvpn-ca" -type d 2>/dev/null | head -1)"
[ -z "$OVPN_CA" ] && OVPN_CA="/root/openvpn-ca"
[ ! -d "$OVPN_CA" ] && error "PKI introuvable."

CCD_DIR="/etc/openvpn/ccd"
ADMIN_HOME="$(dirname "$OVPN_CA")"
REAL_USER="$(stat -c '%U' "$OVPN_CA")"

header "Révocation d'un utilisateur VPN"

# ── Lister les utilisateurs révocables ───────────────────────────────────────
echo -e "${BOLD}Utilisateurs existants :${NC}"
echo ""

USERS=()
INDEX=0

# Techniciens
for CCD in "$CCD_DIR"/tech-* "$CCD_DIR"/temp-*; do
    [ -f "$CCD" ] || continue
    NAME=$(basename "$CCD")
    # Récupérer infos depuis le CCD
    TYPE=$(echo "$NAME" | cut -d'-' -f1)
    EXPIRE=$(grep "Expire" "$CCD" 2>/dev/null | awk '{print $NF}' || echo "inconnu")
    IP=$(grep "ifconfig-push" "$CCD" 2>/dev/null | awk '{print $2}' || echo "?")

    # Vérifier si le certificat existe encore
    CERT_STATUS="actif"
    if [ -f "$OVPN_CA/pki/revoked/certs_by_serial" ]; then
        SERIAL=$(openssl x509 -in "$OVPN_CA/pki/issued/$NAME.crt" \
            -noout -serial 2>/dev/null | cut -d= -f2 || echo "")
        if grep -q "$SERIAL" "$OVPN_CA/pki/revoked/certs_by_serial" 2>/dev/null; then
            CERT_STATUS="${RED}déjà révoqué${NC}"
        fi
    fi

    INDEX=$((INDEX + 1))
    USERS+=("$NAME")

    if [[ "$NAME" == tech-* ]]; then
        echo -e "  ${CYAN}[$INDEX]${NC} ${BOLD}$NAME${NC}  (technicien — IP: $IP — expire: $EXPIRE) — $CERT_STATUS"
    else
        echo -e "  ${YELLOW}[$INDEX]${NC} ${BOLD}$NAME${NC}  (temporaire — IP: $IP — expire: $EXPIRE) — $CERT_STATUS"
    fi
done

if [ ${#USERS[@]} -eq 0 ]; then
    warn "Aucun utilisateur (technicien ou temporaire) trouvé."
    exit 0
fi

echo ""
echo -e "  ${RED}[0]${NC} Annuler"
echo ""

# ── Sélection ────────────────────────────────────────────────────────────────
while true; do
    read -p "Numéro de l'utilisateur à révoquer : " CHOICE
    [ "$CHOICE" = "0" ] && echo "Annulé." && exit 0
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#USERS[@]}" ]; then
        TARGET="${USERS[$((CHOICE - 1))]}"
        break
    fi
    warn "Saisir un numéro entre 0 et ${#USERS[@]}"
done

# ── Confirmation avec avertissement fort ─────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ATTENTION — ACTION IRRÉVERSIBLE               ║${NC}"
echo -e "${RED}${BOLD}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Utilisateur ciblé : ${YELLOW}${BOLD}$TARGET${NC}"
echo ""
echo -e "  Ce qui va être supprimé :"
echo -e "    • Certificat révoqué dans la PKI"
echo -e "    • Fichier CCD : $CCD_DIR/$TARGET"
echo -e "    • Fichier .ovpn : $ADMIN_HOME/$TARGET.ovpn (si présent)"
echo -e "    • La connexion active sera coupée immédiatement"
echo ""
echo -e "  ${RED}Cette action ne peut pas être annulée.${NC}"
echo ""
read -p "Taper le nom exact de l'utilisateur pour confirmer : " CONFIRM_NAME

if [ "$CONFIRM_NAME" != "$TARGET" ]; then
    warn "Nom incorrect — opération annulée."
    exit 1
fi

echo ""
echo -e "${BOLD}${CYAN}═══ Révocation de $TARGET ═══${NC}"
echo ""

# ── Révocation du certificat ──────────────────────────────────────────────────
if [ -f "$OVPN_CA/pki/issued/$TARGET.crt" ]; then
    step "Révocation du certificat dans la PKI..."
    echo "yes" | sudo -u "$REAL_USER" \
        bash -c "cd $OVPN_CA && ./easyrsa revoke $TARGET" \
        > /dev/null 2>&1
    success "Certificat révoqué"
else
    warn "Certificat $TARGET.crt introuvable dans la PKI — déjà supprimé ?"
fi

# ── Regénération de la CRL ────────────────────────────────────────────────────
step "Regénération de la CRL..."
sudo -u "$REAL_USER" \
    bash -c "cd $OVPN_CA && ./easyrsa gen-crl" \
    > /dev/null 2>&1
cp "$OVPN_CA/pki/crl.pem" /etc/openvpn/crl.pem
chmod 644 /etc/openvpn/crl.pem
success "CRL mise à jour — connexion refusée immédiatement"

# ── Suppression du fichier CCD ────────────────────────────────────────────────
if [ -f "$CCD_DIR/$TARGET" ]; then
    step "Suppression du fichier CCD..."
    rm -f "$CCD_DIR/$TARGET"
    success "Fichier CCD supprimé : $CCD_DIR/$TARGET"
else
    warn "Fichier CCD introuvable : $CCD_DIR/$TARGET"
fi

# ── Suppression du .ovpn ──────────────────────────────────────────────────────
if [ -f "$ADMIN_HOME/$TARGET.ovpn" ]; then
    step "Suppression du fichier .ovpn..."
    rm -f "$ADMIN_HOME/$TARGET.ovpn"
    success "Fichier .ovpn supprimé : $ADMIN_HOME/$TARGET.ovpn"
else
    info "Fichier .ovpn non trouvé (peut avoir été transmis) — ignoré"
fi

# ── Suppression des clés et certificats de la PKI ────────────────────────────
step "Nettoyage des fichiers PKI..."
CLEANED=0
for f in \
    "$OVPN_CA/pki/private/$TARGET.key" \
    "$OVPN_CA/pki/issued/$TARGET.crt" \
    "$OVPN_CA/pki/reqs/$TARGET.req"; do
    if [ -f "$f" ]; then
        rm -f "$f"
        success "  Supprimé : $(basename $f)"
        CLEANED=$((CLEANED + 1))
    fi
done
[ "$CLEANED" -eq 0 ] && info "Fichiers PKI déjà absents"

# ── Résumé final ──────────────────────────────────────────────────────────────
header "Révocation terminée ✓"

echo -e "${GREEN}${BOLD}✓ Utilisateur '$TARGET' révoqué et supprimé${NC}"
echo ""
echo -e "  La connexion VPN de $TARGET est refusée ${BOLD}immédiatement${NC}."
echo -e "  Aucun redémarrage du service nécessaire."
echo ""
echo -e "${BOLD}Vérification :${NC}"
echo -e "  ${CYAN}sudo cat /var/log/openvpn-status.log${NC}   — vérifier qu'il n'est plus connecté"
echo -e "  ${CYAN}sudo openssl crl -in /etc/openvpn/crl.pem -noout -text | grep -A2 'Revoked'${NC}"
echo ""
