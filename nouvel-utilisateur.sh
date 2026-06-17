#!/bin/bash
# =============================================================================
# nouvel-utilisateur.sh — Création d'un technicien ou compte temporaire
# Usage : sudo nouvel-utilisateur.sh
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

[ "$EUID" -ne 0 ] && error "Lancer avec sudo : sudo nouvel-utilisateur.sh"

OVPN_CA="$(find /home -maxdepth 2 -name "openvpn-ca" -type d 2>/dev/null | head -1)"
[ -z "$OVPN_CA" ] && OVPN_CA="/root/openvpn-ca"
[ ! -d "$OVPN_CA" ] && error "PKI introuvable."

SITES_CSV="/etc/openvpn/sites.csv"
CCD_DIR="/etc/openvpn/ccd"
SCRIPTS_DIR="/etc/openvpn/scripts"
SERVER_IP=$(cat /etc/openvpn/server_ip.txt 2>/dev/null || echo "127.0.0.1")
ADMIN_HOME="$(dirname "$OVPN_CA")"
REAL_USER="$(stat -c '%U' "$OVPN_CA")"

header "Création d'un utilisateur VPN"

# ── Type de compte ────────────────────────────────────────────────────────────
echo -e "${BOLD}Type de compte :${NC}"
echo "  1) Technicien  — accès permanent à tous les sites (mis à jour automatiquement)"
echo "  2) Temporaire  — accès limité à certains sites, durée définie"
echo ""
while true; do
    read -p "Choix [1/2] : " TYPE_CHOICE
    case "$TYPE_CHOICE" in
        1) USER_TYPE="technicien"; break ;;
        2) USER_TYPE="temporaire"; break ;;
        *) warn "Saisir 1 ou 2" ;;
    esac
done

# ── Nom ───────────────────────────────────────────────────────────────────────
echo ""
[ "$USER_TYPE" = "technicien" ] && PREFIX="tech" || PREFIX="temp"
echo -e "${BOLD}Création d'un compte ${USER_TYPE}${NC}"

while true; do
    read -p "  Prénom ou identifiant (ex: alice, bob) : " USER_SHORT
    USER_SHORT=$(echo "$USER_SHORT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    [ -z "$USER_SHORT" ] && warn "Nom requis." && continue
    USER_NAME="${PREFIX}-${USER_SHORT}"
    if [ -f "$CCD_DIR/$USER_NAME" ]; then
        warn "L'utilisateur '$USER_NAME' existe déjà."
        continue
    fi
    break
done

# ── Durée ─────────────────────────────────────────────────────────────────────
echo ""
if [ "$USER_TYPE" = "technicien" ]; then
    read -p "  Durée du certificat en jours [825] : " CERT_EXPIRE
    CERT_EXPIRE="${CERT_EXPIRE:-825}"
else
    echo "  Durées courantes : 7 (semaine), 30 (mois), 90 (trimestre)"
    read -p "  Durée du certificat en jours [30] : " CERT_EXPIRE
    CERT_EXPIRE="${CERT_EXPIRE:-30}"
fi

# ── Sites accessibles (temporaires) ──────────────────────────────────────────
ALLOWED_SITES=()
if [ "$USER_TYPE" = "temporaire" ]; then
    echo ""
    echo -e "${BOLD}Sites disponibles :${NC}"
    SITE_LIST=()
    while IFS=',' read -r site vpn_net vpn_mask phys_net phys_mask; do
        [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
        SITE_LIST+=("$site")
        echo -e "  • ${CYAN}$site${NC}  (VPN: $vpn_net/$vpn_mask  →  physique: $phys_net)"
    done < "$SITES_CSV"

    if [ ${#SITE_LIST[@]} -eq 0 ]; then
        warn "Aucun site configuré. Créer d'abord un site avec : sudo nouveau-site.sh"
        exit 1
    fi

    echo ""
    while true; do
        read -p "  Sites autorisés (séparés par espaces) : " SITES_INPUT
        [ -z "$SITES_INPUT" ] && warn "Au moins un site requis." && continue
        VALID=true
        for s in $SITES_INPUT; do
            if ! grep -q "^${s}," "$SITES_CSV"; then
                warn "Site '$s' introuvable dans sites.csv"
                VALID=false
            fi
        done
        $VALID && ALLOWED_SITES=($SITES_INPUT) && break
    done
fi

# ── Calcul IP fixe sans collision ─────────────────────────────────────────────
if [ "$USER_TYPE" = "technicien" ]; then
    EXISTING=$(ls "$CCD_DIR"/tech-* 2>/dev/null | wc -l)
    FIXED_IP="10.10.0.$((20 + EXISTING))"
    [ "$((20 + EXISTING))" -gt 69 ] && error "Plage techniciens saturée (max 50)."
else
    EXISTING=$(ls "$CCD_DIR"/temp-* 2>/dev/null | wc -l)
    FIXED_IP="10.10.0.$((100 + EXISTING))"
    [ "$((100 + EXISTING))" -gt 149 ] && error "Plage temporaires saturée (max 50)."
fi

EXPIRY_DATE=$(date -d "+${CERT_EXPIRE} days" '+%d/%m/%Y' 2>/dev/null || \
              date -v "+${CERT_EXPIRE}d" '+%d/%m/%Y' 2>/dev/null || \
              echo "dans $CERT_EXPIRE jours")

# ── Récapitulatif ─────────────────────────────────────────────────────────────
echo ""
header "Récapitulatif"
echo -e "  Identifiant   : ${YELLOW}$USER_NAME${NC}"
echo -e "  Type          : ${YELLOW}$USER_TYPE${NC}"
echo -e "  IP VPN fixe   : ${YELLOW}$FIXED_IP${NC}"
echo -e "  Certificat    : ${YELLOW}$CERT_EXPIRE jours${NC}"
if [ "$USER_TYPE" = "temporaire" ]; then
    echo -e "  Expire le     : ${YELLOW}$EXPIRY_DATE${NC}"
    echo -e "  Sites         : ${YELLOW}${ALLOWED_SITES[*]}${NC}"
else
    echo -e "  Accès         : ${YELLOW}tous les sites (mis à jour automatiquement)${NC}"
fi
echo ""
read -p "Confirmer la création ? [o/N] " CONFIRM
[[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé."; exit 0; }

echo ""
echo -e "${BOLD}${CYAN}═══ Création de $USER_NAME ═══${NC}"
echo ""

# ── Certificat ────────────────────────────────────────────────────────────────
step "Génération de la clé et de la requête..."
echo "" | sudo -u "$REAL_USER" \
    bash -c "cd $OVPN_CA && EASYRSA_CERT_EXPIRE=$CERT_EXPIRE ./easyrsa gen-req $USER_NAME nopass" \
    > /dev/null 2>&1
success "Clé privée générée : $USER_NAME.key"

step "Signature du certificat..."
echo "yes" | sudo -u "$REAL_USER" \
    bash -c "cd $OVPN_CA && EASYRSA_CERT_EXPIRE=$CERT_EXPIRE ./easyrsa sign-req client $USER_NAME" \
    > /dev/null 2>&1
success "Certificat signé : $USER_NAME.crt (expire le $EXPIRY_DATE)"

# ── Fichier CCD ───────────────────────────────────────────────────────────────
step "Création du fichier CCD..."
EXPIRY_ISO=$(date -d "+${CERT_EXPIRE} days" '+%Y-%m-%d' 2>/dev/null || echo "dans $CERT_EXPIRE jours")

{
    echo "# Utilisateur : $USER_NAME"
    echo "# Type        : $USER_TYPE"
    echo "# Créé le     : $(date '+%Y-%m-%d %H:%M')"
    echo "# Expire le   : $EXPIRY_ISO"
    echo ""
    echo "# IP fixe dans le tunnel"
    echo "ifconfig-push $FIXED_IP 255.255.0.0"
    echo ""
} > "$CCD_DIR/$USER_NAME"

if [ "$USER_TYPE" = "technicien" ]; then
    echo "# Routes vers tous les sites (générées statiquement) :" >> "$CCD_DIR/$USER_NAME"
    while IFS=',' read -r site vpn_net vpn_mask rest; do
        [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
        echo "push \"route $vpn_net $vpn_mask\"   # $site" >> "$CCD_DIR/$USER_NAME"
    done < "$SITES_CSV"
    success "CCD créé avec accès à tous les sites actuels"
else
    echo "# Accès limité aux sites suivants :" >> "$CCD_DIR/$USER_NAME"
    for site in "${ALLOWED_SITES[@]}"; do
        VPN_NET=$(grep "^${site}," "$SITES_CSV" | cut -d',' -f2)
        VPN_MASK=$(grep "^${site}," "$SITES_CSV" | cut -d',' -f3)
        echo "push \"route $VPN_NET $VPN_MASK\"   # $site" >> "$CCD_DIR/$USER_NAME"
    done
    success "CCD créé avec accès limité à : ${ALLOWED_SITES[*]}"
fi

# ── Génération du .ovpn ───────────────────────────────────────────────────────
step "Génération du fichier .ovpn..."
OVPN_FILE="$ADMIN_HOME/${USER_NAME}.ovpn"
cat > "$OVPN_FILE" <<EOF
# Profil OpenVPN — $USER_NAME
# Type : $USER_TYPE
# Généré le $(date '+%Y-%m-%d %H:%M')
# Expire le : $EXPIRY_ISO

client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
verb 3

<ca>
$(cat "$OVPN_CA/pki/ca.crt")
</ca>
<cert>
$(cat "$OVPN_CA/pki/issued/$USER_NAME.crt")
</cert>
<key>
$(cat "$OVPN_CA/pki/private/$USER_NAME.key")
</key>
<tls-auth>
$(cat "$OVPN_CA/ta.key")
</tls-auth>
key-direction 1
EOF
chmod 600 "$OVPN_FILE"
success "Fichier .ovpn généré : $OVPN_FILE"

# ── Résumé final ──────────────────────────────────────────────────────────────
header "Utilisateur $USER_NAME créé ✓"

echo -e "${GREEN}${BOLD}✓ Compte '$USER_NAME' créé avec succès${NC}"
echo ""
echo -e "${BOLD}Fichier .ovpn à transmettre (de façon sécurisée) :${NC}"
echo -e "  ${YELLOW}$OVPN_FILE${NC}"
echo ""

if [ "$USER_TYPE" = "technicien" ]; then
    SITE_COUNT=$(grep -c "^[^#]" "$SITES_CSV" 2>/dev/null || echo 0)
    echo -e "${BOLD}Accès :${NC} $SITE_COUNT site(s) actuel(s) — les nouveaux sites seront ajoutés automatiquement"
    echo -e "${BOLD}Le .ovpn n'a pas besoin d'être regénéré pour les futurs sites.${NC}"
else
    echo -e "${BOLD}Accès limité à :${NC} ${ALLOWED_SITES[*]}"
    echo -e "${BOLD}Expire le      :${NC} $EXPIRY_DATE"
    echo -e "${BOLD}Pour étendre l'accès :${NC} révoquer et recréer le compte"
fi

echo ""
echo -e "${BOLD}Pour révoquer immédiatement ce compte :${NC}"
echo -e "  ${CYAN}cd ~/openvpn-ca${NC}"
echo -e "  ${CYAN}./easyrsa revoke $USER_NAME${NC}"
echo -e "  ${CYAN}./easyrsa gen-crl && sudo cp pki/crl.pem /etc/openvpn/${NC}"
echo ""
