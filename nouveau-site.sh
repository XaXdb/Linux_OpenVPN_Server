#!/bin/bash
# =============================================================================
# nouveau-site.sh — Ajout automatique d'un site client au VPN GTB/GTC
# Usage : sudo nouveau-site.sh
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

[ "$EUID" -ne 0 ] && error "Lancer avec sudo : sudo nouveau-site.sh"

OVPN_CA="$(find /home -maxdepth 2 -name "openvpn-ca" -type d 2>/dev/null | head -1)"
[ -z "$OVPN_CA" ] && OVPN_CA="/root/openvpn-ca"
[ ! -d "$OVPN_CA" ] && error "PKI introuvable. Vérifier le répertoire openvpn-ca."

SITES_CSV="/etc/openvpn/sites.csv"
CCD_DIR="/etc/openvpn/ccd"
SCRIPTS_DIR="/etc/openvpn/scripts"
SERVER_IP=$(cat /etc/openvpn/server_ip.txt 2>/dev/null || echo "127.0.0.1")
ADMIN_HOME="$(dirname "$OVPN_CA")"
REAL_USER="$(stat -c '%U' "$OVPN_CA")"

header "Ajout d'un nouveau site VPN"

# ── Calcul du prochain numéro de site ─────────────────────────────────────────
NEXT_NUM=1
while IFS=',' read -r site vpn_net rest; do
    [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
    OCTET=$(echo "$vpn_net" | cut -d. -f3)
    [ "$OCTET" -ge "$NEXT_NUM" ] && NEXT_NUM=$((OCTET + 1))
done < "$SITES_CSV"

SUGGESTED_VPN="10.10.${NEXT_NUM}.0"
info "Prochain sous-réseau VPN disponible : ${YELLOW}${SUGGESTED_VPN}/24${NC}"
echo ""

# ── Collecte des informations ─────────────────────────────────────────────────
echo -e "${BOLD}Informations du nouveau site :${NC}"
echo ""

while true; do
    read -p "  Nom du site (ex: site-dupont, site-03) : " SITE_NAME
    SITE_NAME=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    [ -z "$SITE_NAME" ] && warn "Le nom ne peut pas être vide." && continue
    if grep -q "^${SITE_NAME}," "$SITES_CSV" 2>/dev/null; then
        warn "Un site '$SITE_NAME' existe déjà dans sites.csv."
        continue
    fi
    if [ -f "$CCD_DIR/$SITE_NAME" ]; then
        warn "Un fichier CCD '$SITE_NAME' existe déjà."
        continue
    fi
    break
done

read -p "  Réseau physique du site (ex: 192.168.1.0) [192.168.1.0] : " PHYS_NET
PHYS_NET="${PHYS_NET:-192.168.1.0}"

read -p "  Masque réseau physique [255.255.255.0] : " PHYS_MASK
PHYS_MASK="${PHYS_MASK:-255.255.255.0}"

read -p "  Sous-réseau VPN pour ce site [$SUGGESTED_VPN] : " VPN_NET
VPN_NET="${VPN_NET:-$SUGGESTED_VPN}"
VPN_MASK="255.255.255.0"

VPN_PC_IP=$(echo "$VPN_NET" | sed 's/\.0$/\.1/')

read -p "  Description / nom du client (optionnel) : " SITE_DESC
read -p "  Durée du certificat en jours [825] : " CERT_EXPIRE
CERT_EXPIRE="${CERT_EXPIRE:-825}"

# ── Récapitulatif ─────────────────────────────────────────────────────────────
echo ""
header "Récapitulatif"
echo -e "  Nom du site       : ${YELLOW}$SITE_NAME${NC}"
[ -n "$SITE_DESC" ] && echo -e "  Client            : ${YELLOW}$SITE_DESC${NC}"
echo -e "  Réseau physique   : ${YELLOW}$PHYS_NET / $PHYS_MASK${NC}"
echo -e "  Sous-réseau VPN   : ${YELLOW}$VPN_NET / $VPN_MASK${NC}"
echo -e "  IP mini-PC (VPN)  : ${YELLOW}$VPN_PC_IP${NC}"
echo -e "  Certificat valide : ${YELLOW}$CERT_EXPIRE jours${NC}"
echo ""
read -p "Confirmer la création ? [o/N] " CONFIRM
[[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé."; exit 0; }

echo ""
echo -e "${BOLD}${CYAN}═══ Création du site $SITE_NAME ═══${NC}"
echo ""

# ── Certificat ────────────────────────────────────────────────────────────────
step "Génération de la clé et de la requête (gen-req)..."
echo "" | sudo -u "$REAL_USER" \
    bash -c "cd $OVPN_CA && EASYRSA_CERT_EXPIRE=$CERT_EXPIRE ./easyrsa gen-req $SITE_NAME nopass" \
    > /dev/null 2>&1
success "Clé privée générée : $SITE_NAME.key"

step "Signature du certificat (sign-req client)..."
echo "yes" | sudo -u "$REAL_USER" \
    bash -c "cd $OVPN_CA && EASYRSA_CERT_EXPIRE=$CERT_EXPIRE ./easyrsa sign-req client $SITE_NAME" \
    > /dev/null 2>&1
success "Certificat signé : $SITE_NAME.crt"

# ── Fichier CCD ───────────────────────────────────────────────────────────────
step "Création du fichier CCD..."
cat > "$CCD_DIR/$SITE_NAME" <<EOF
# Site : $SITE_NAME${SITE_DESC:+ — $SITE_DESC}
# Réseau physique : $PHYS_NET / $PHYS_MASK
# Créé le : $(date '+%Y-%m-%d %H:%M')

# IP fixe du mini-PC dans le tunnel VPN
ifconfig-push $VPN_PC_IP 255.255.0.0

# Réseau VPN de ce site (pour le routage interne OpenVPN)
iroute $VPN_NET $VPN_MASK

# Ce site ne reçoit PAS les routes des autres sites
route-nopull
EOF
success "Fichier CCD créé : $CCD_DIR/$SITE_NAME"

# ── sites.csv ─────────────────────────────────────────────────────────────────
step "Mise à jour de sites.csv..."
echo "$SITE_NAME,$VPN_NET,$VPN_MASK,$PHYS_NET,$PHYS_MASK" >> "$SITES_CSV"
success "sites.csv mis à jour"

# ── server.conf ───────────────────────────────────────────────────────────────
step "Ajout de la route dans server.conf..."
if ! grep -q "route $VPN_NET $VPN_MASK" /etc/openvpn/server.conf; then
    echo "route $VPN_NET $VPN_MASK   # $SITE_NAME" >> /etc/openvpn/server.conf
    success "Route ajoutée dans server.conf"
else
    warn "Route déjà présente dans server.conf — ignorée"
fi

# ── Règles iptables GRANULAIRES (une règle par site) ──────────────────────────
step "Ajout des règles iptables granulaires..."

# Techniciens → ce site uniquement (règle spécifique, pas globale)
iptables -I FORWARD 1 \
    -i tun0 -s 10.10.0.0/24 -d "$VPN_NET/24" \
    -m comment --comment "tech→$SITE_NAME" \
    -j ACCEPT
success "  Règle : techniciens (10.10.0.0/24) → $SITE_NAME ($VPN_NET/24) : ACCEPT"

# Bloquer ce site vers tous les autres sous-réseaux VPN
iptables -A FORWARD \
    -i tun0 -s "$VPN_NET/24" -d 10.10.0.0/8 \
    -m comment --comment "$SITE_NAME→autres-interdit" \
    -j DROP
success "  Règle : $SITE_NAME → autres réseaux VPN : DROP"

netfilter-persistent save > /dev/null 2>&1
success "Règles iptables sauvegardées"

# ── Mise à jour des CCD techniciens (statique, pas client-connect) ────────────
TECH_COUNT=$(ls "$CCD_DIR"/tech-* 2>/dev/null | wc -l)
if [ "$TECH_COUNT" -gt 0 ]; then
    step "Mise à jour des CCD de $TECH_COUNT technicien(s) existant(s)..."
    "$SCRIPTS_DIR/update-tech-ccd.sh"
    success "CCD techniciens mis à jour — ils verront $SITE_NAME à la prochaine connexion"
else
    info "Aucun technicien existant — les futurs techniciens auront accès à ce site automatiquement"
fi

# ── Génération du .ovpn ───────────────────────────────────────────────────────
step "Génération du fichier .ovpn..."
OVPN_FILE="$ADMIN_HOME/${SITE_NAME}.ovpn"
cat > "$OVPN_FILE" <<EOF
# Profil OpenVPN — $SITE_NAME${SITE_DESC:+ ($SITE_DESC)}
# Généré le $(date '+%Y-%m-%d %H:%M')
# USAGE : mini-PC Linux/Windows du site

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

# Ce site ne reçoit pas les routes des autres
route-nopull

<ca>
$(cat "$OVPN_CA/pki/ca.crt")
</ca>
<cert>
$(cat "$OVPN_CA/pki/issued/$SITE_NAME.crt")
</cert>
<key>
$(cat "$OVPN_CA/pki/private/$SITE_NAME.key")
</key>
<tls-auth>
$(cat "$OVPN_CA/ta.key")
</tls-auth>
key-direction 1
EOF
chmod 600 "$OVPN_FILE"
success "Fichier .ovpn généré : $OVPN_FILE"

# ── Redémarrage OpenVPN ───────────────────────────────────────────────────────
step "Redémarrage du service OpenVPN (prise en compte de la nouvelle route)..."
systemctl restart openvpn@server
sleep 2
if systemctl is-active --quiet openvpn@server; then
    success "Service redémarré"
else
    warn "Service instable — vérifier : sudo journalctl -xeu openvpn@server"
fi

# ── Résumé final ──────────────────────────────────────────────────────────────
header "Site $SITE_NAME créé ✓"

echo -e "${GREEN}${BOLD}✓ Site '$SITE_NAME' ajouté au VPN${NC}"
echo ""
echo -e "${BOLD}Fichier .ovpn à déployer sur le mini-PC du site :${NC}"
echo -e "  ${YELLOW}$OVPN_FILE${NC}"
echo ""
echo -e "${BOLD}Configuration NAT 1:1 à appliquer sur le mini-PC Linux du site :${NC}"
echo -e "  ${CYAN}# 1. Activer le routage${NC}"
echo -e "  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf && sysctl -p"
echo ""
echo -e "  ${CYAN}# 2. NAT 1:1 bidirectionnel${NC}"
echo -e "  iptables -t nat -A PREROUTING  -d $VPN_NET/24 -j NETMAP --to $PHYS_NET/24"
echo -e "  iptables -t nat -A POSTROUTING -s $PHYS_NET/24 -j NETMAP --to $VPN_NET/24"
echo -e "  iptables-save > /etc/iptables/rules.v4"
echo ""
echo -e "${BOLD}Test de validation (depuis le serveur) :${NC}"
echo -e "  ${CYAN}# Surveiller le trafic VPN entrant${NC}"
echo -e "  sudo tcpdump -ni tun0 -n host $VPN_PC_IP"
echo -e "  ${CYAN}# Surveiller le trafic LAN sur le mini-PC du site${NC}"
echo -e "  sudo tcpdump -ni eth0 -n"
echo ""
EXAMPLE_VPN=$(echo "$VPN_NET" | sed 's/\.0$/.100/')
EXAMPLE_PHYS=$(echo "$PHYS_NET" | sed 's/\.0$/.100/')
echo -e "${BOLD}Les techniciens accèdent aux équipements via :${NC}"
echo -e "  ${CYAN}$EXAMPLE_VPN${NC}  →  équipement ${CYAN}$EXAMPLE_PHYS${NC} sur le réseau physique du site"
echo ""
