#!/bin/bash
# =============================================================================
# install.sh — Installation automatique du serveur OpenVPN GTB/GTC
# Compatible : Ubuntu 22/24 LTS, Debian 11/12, Raspberry Pi OS (Debian)
# Usage : sudo bash install.sh
# =============================================================================

set -e

# ── Couleurs ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[....] $1${NC}"; }
step()    { echo -e "${CYAN}[....] $1${NC}"; }
success() { echo -e "${GREEN}[ OK ] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
error()   { echo -e "${RED}[FAIL] $1${NC}"; exit 1; }

# Barre de progression globale
STEP_CURRENT=0
STEP_TOTAL=22

progress() {
    STEP_CURRENT=$((STEP_CURRENT + 1))
    PCT=$((STEP_CURRENT * 100 / STEP_TOTAL))
    FILLED=$((PCT / 5))
    EMPTY=$((20 - FILLED))
    BAR="["
    for i in $(seq 1 $FILLED); do BAR="${BAR}█"; done
    for i in $(seq 1 $EMPTY);  do BAR="${BAR}░"; done
    BAR="${BAR}]"
    echo -e "\n${BOLD}${CYAN}$BAR ${PCT}% — $1${NC}"
}

# ── Vérifications préalables ──────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Ce script doit être lancé en root (sudo bash install.sh)"

clear
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║     Installation OpenVPN GTB/GTC v2.0        ║"
echo "  ║     Ubuntu / Debian / Raspberry Pi OS        ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}Ce script va installer et configurer :${NC}"
echo "  [1/7] Paquets système    — openvpn, easy-rsa, iptables-persistent"
echo "  [2/7] PKI                — autorité de certification (CA)"
echo "  [3/7] Certificats serveur — clé, cert, DH, TLS"
echo "  [4/7] Fichiers OpenVPN   — copie dans /etc/openvpn/"
echo "  [5/7] Configuration      — server.conf, CCD, scripts"
echo "  [6/7] Règles iptables    — isolation sites, NAT"
echo "  [7/7] Démarrage          — service + vérification"
echo ""
echo -e "${YELLOW}Durée estimée : 3 à 7 minutes (DH peut être long sur Raspberry Pi)${NC}"
echo ""
read -p "Continuer ? [o/N] " CONFIRM
[[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé."; exit 0; }

# ── Collecte des informations ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}═══ Configuration ═══════════════════════════════════${NC}"
echo ""

step "Détection de l'IP publique..."
DETECTED_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
              curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
              hostname -I | awk '{print $1}')
success "IP détectée : $DETECTED_IP"

echo ""
read -p "  IP publique ou nom de domaine [$DETECTED_IP] : " SERVER_IP
SERVER_IP="${SERVER_IP:-$DETECTED_IP}"

read -p "  Nom de l'organisation [MonEntreprise] : " ORG
ORG="${ORG:-MonEntreprise}"

read -p "  Ville [Lyon] : " CITY
CITY="${CITY:-Lyon}"

read -p "  Email admin [admin@monentreprise.fr] : " EMAIL
EMAIL="${EMAIL:-admin@monentreprise.fr}"

ADMIN_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
OVPN_CA="$ADMIN_HOME/openvpn-ca"
SCRIPTS_DIR="/etc/openvpn/scripts"
CCD_DIR="/etc/openvpn/ccd"
SITES_CSV="/etc/openvpn/sites.csv"
REAL_USER="${SUDO_USER:-$USER}"

echo ""
echo -e "${BOLD}Récapitulatif :${NC}"
echo -e "  Serveur    : ${YELLOW}$SERVER_IP${NC}"
echo -e "  Org        : ${YELLOW}$ORG${NC}"
echo -e "  PKI        : ${YELLOW}$OVPN_CA${NC}"
echo ""
read -p "Lancer l'installation ? [o/N] " GO
[[ "$GO" =~ ^[oO]$ ]] || { echo "Annulé."; exit 0; }

echo ""
echo -e "${BOLD}${CYAN}═══ Progression ════════════════════════════════════${NC}"

# ══════════════════════════════════════════════════════════════════════════════
# 1/7 — PAQUETS
# ══════════════════════════════════════════════════════════════════════════════
progress "1/7 — Mise à jour des dépôts (apt update)"
step "Mise à jour de la liste des paquets..."
apt-get update -qq 2>&1 | while IFS= read -r line; do
    echo -ne "\r  ${CYAN}apt update...${NC} $line                    "
done
echo -ne "\r                                                              \r"
success "Dépôts mis à jour"

progress "1/7 — Installation d'OpenVPN"
step "Installation de openvpn..."
DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn > /dev/null 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
    echo -ne "\r  ${CYAN}[....] Installation openvpn...${NC}   "
    sleep 0.4
    echo -ne "\r  ${CYAN}[....] Installation openvpn....${NC}  "
    sleep 0.4
done
wait $PID
success "openvpn installé"

progress "1/7 — Installation de Easy-RSA"
step "Installation de easy-rsa..."
DEBIAN_FRONTEND=noninteractive apt-get install -y easy-rsa > /dev/null 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
    echo -ne "\r  ${CYAN}[....] Installation easy-rsa...${NC}  "
    sleep 0.4
    echo -ne "\r  ${CYAN}[....] Installation easy-rsa....${NC} "
    sleep 0.4
done
wait $PID
success "easy-rsa installé"

progress "1/7 — Installation de iptables-persistent"
step "Installation de iptables-persistent..."
DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent curl > /dev/null 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
    echo -ne "\r  ${CYAN}[....] Installation iptables-persistent...${NC}  "
    sleep 0.4
    echo -ne "\r  ${CYAN}[....] Installation iptables-persistent....${NC} "
    sleep 0.4
done
wait $PID
success "iptables-persistent et curl installés"

# ══════════════════════════════════════════════════════════════════════════════
# 2/7 — PKI
# ══════════════════════════════════════════════════════════════════════════════
progress "2/7 — Initialisation de la PKI"
step "Création du répertoire openvpn-ca..."
sudo -u "$REAL_USER" make-cadir "$OVPN_CA" 2>/dev/null || true
success "Répertoire PKI créé : $OVPN_CA"

progress "2/7 — Écriture du fichier vars"
cat > "$OVPN_CA/vars" <<EOF
set_var EASYRSA_REQ_COUNTRY    "FR"
set_var EASYRSA_REQ_PROVINCE   "Rhone-Alpes"
set_var EASYRSA_REQ_CITY       "$CITY"
set_var EASYRSA_REQ_ORG        "$ORG"
set_var EASYRSA_REQ_EMAIL      "$EMAIL"
set_var EASYRSA_REQ_OU         "GTB"
set_var EASYRSA_CA_EXPIRE      3650
set_var EASYRSA_CERT_EXPIRE    825
EOF
success "Fichier vars configuré"

progress "2/7 — init-pki"
step "Initialisation de la PKI (easyrsa init-pki)..."
sudo -u "$REAL_USER" bash -c "cd $OVPN_CA && ./easyrsa init-pki" > /dev/null 2>&1
success "PKI initialisée"

progress "2/7 — Création de l'autorité de certification (CA)"
step "Génération du certificat CA (peut prendre 10-20s)..."
echo "" | sudo -u "$REAL_USER" bash -c "cd $OVPN_CA && ./easyrsa build-ca nopass" > /dev/null 2>&1 &
PID=$!
while kill -0 $PID 2>/dev/null; do
    echo -ne "\r  ${CYAN}[....] Génération CA...${NC}   "
    sleep 0.5
    echo -ne "\r  ${CYAN}[....] Génération CA....${NC}  "
    sleep 0.5
done
wait $PID
success "Autorité de certification créée (ca.crt)"

# ══════════════════════════════════════════════════════════════════════════════
# 3/7 — CERTIFICATS SERVEUR
# ══════════════════════════════════════════════════════════════════════════════
progress "3/7 — Génération de la clé et requête serveur"
step "easyrsa gen-req serveur..."
echo "" | sudo -u "$REAL_USER" bash -c "cd $OVPN_CA && ./easyrsa gen-req serveur nopass" > /dev/null 2>&1
success "Clé privée serveur générée (serveur.key)"

progress "3/7 — Signature du certificat serveur"
step "easyrsa sign-req server serveur..."
echo "yes" | sudo -u "$REAL_USER" bash -c "cd $OVPN_CA && ./easyrsa sign-req server serveur" > /dev/null 2>&1
success "Certificat serveur signé (serveur.crt)"

progress "3/7 — Paramètres Diffie-Hellman (étape longue)"
step "easyrsa gen-dh — peut prendre 1 à 5 minutes sur Raspberry Pi..."
sudo -u "$REAL_USER" bash -c "cd $OVPN_CA && ./easyrsa gen-dh" > /dev/null 2>&1 &
PID=$!
ELAPSED=0
while kill -0 $PID 2>/dev/null; do
    echo -ne "\r  ${YELLOW}[....] Génération DH en cours... ${ELAPSED}s${NC}   "
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
wait $PID
echo -ne "\r                                                         \r"
success "Paramètres DH générés en ${ELAPSED}s (dh.pem)"

progress "3/7 — Clé TLS-Auth"
step "Génération de la clé TLS (ta.key)..."
openvpn --genkey secret "$OVPN_CA/ta.key" 2>/dev/null || \
    sudo -u "$REAL_USER" openvpn --genkey --secret "$OVPN_CA/ta.key"
success "Clé TLS-Auth générée (ta.key)"

progress "3/7 — Génération de la CRL initiale"
step "easyrsa gen-crl..."
sudo -u "$REAL_USER" bash -c "cd $OVPN_CA && ./easyrsa gen-crl" > /dev/null 2>&1
success "CRL initiale générée (crl.pem)"

# ══════════════════════════════════════════════════════════════════════════════
# 4/7 — DÉPLOIEMENT DES FICHIERS
# ══════════════════════════════════════════════════════════════════════════════
progress "4/7 — Copie des certificats dans /etc/openvpn/"
step "Copie de ca.crt, serveur.crt, serveur.key, dh.pem, ta.key, crl.pem..."
cp "$OVPN_CA/pki/ca.crt"             /etc/openvpn/ && success "  ca.crt"
cp "$OVPN_CA/pki/issued/serveur.crt" /etc/openvpn/ && success "  serveur.crt"
cp "$OVPN_CA/pki/private/serveur.key" /etc/openvpn/ && success "  serveur.key"
cp "$OVPN_CA/pki/dh.pem"             /etc/openvpn/ && success "  dh.pem"
cp "$OVPN_CA/ta.key"                  /etc/openvpn/ && success "  ta.key"
cp "$OVPN_CA/pki/crl.pem"            /etc/openvpn/ && success "  crl.pem"
chmod 600 /etc/openvpn/serveur.key /etc/openvpn/ta.key
chmod 644 /etc/openvpn/crl.pem
mkdir -p "$CCD_DIR" "$SCRIPTS_DIR"
success "Tous les fichiers déployés"

# ══════════════════════════════════════════════════════════════════════════════
# 5/7 — CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════
progress "5/7 — Création de server.conf"
cat > /etc/openvpn/server.conf <<'EOF'
port 1194
proto udp
dev tun

ca   ca.crt
cert serveur.crt
key  serveur.key
dh   dh.pem
tls-auth ta.key 0

cipher AES-256-GCM
auth SHA256
tls-version-min 1.2

# Pool VPN pour les clients directs (techniciens, temporaires)
server 10.10.0.0 255.255.255.0

# Topologie moderne
topology subnet

# Routage par client
client-config-dir /etc/openvpn/ccd

# Isolation inter-sites (géré par iptables — NE PAS activer client-to-client)
# client-to-client

# Révocation
crl-verify /etc/openvpn/crl.pem

keepalive 10 120
persist-key
persist-tun
user  nobody
group nogroup

log-append /var/log/openvpn.log
status     /var/log/openvpn-status.log
verb 3
EOF
success "server.conf créé (/16 → /24 pour le pool VPN)"

progress "5/7 — Création du fichier sites.csv"
cat > "$SITES_CSV" <<'EOF'
# FORMAT : nom_site,reseau_vpn,masque_vpn,reseau_physique,masque_physique
# Exemple : site-A,10.10.1.0,255.255.255.0,192.168.1.0,255.255.255.0
EOF
success "sites.csv créé ($SITES_CSV)"

progress "5/7 — Création du script update-tech-ccd.sh"
# Remplace client-connect : regénère les CCD techniciens à l'ajout d'un site
cat > "$SCRIPTS_DIR/update-tech-ccd.sh" <<'SCRIPT'
#!/bin/bash
# =============================================================================
# update-tech-ccd.sh — Regénère les CCD de tous les techniciens
# Appelé automatiquement par nouveau-site.sh à chaque ajout de site
# =============================================================================
SITES_CSV="/etc/openvpn/sites.csv"
CCD_DIR="/etc/openvpn/ccd"

for CCD in "$CCD_DIR"/tech-*; do
    [ -f "$CCD" ] || continue
    CLIENT=$(basename "$CCD")
    FIXED_IP=$(grep "ifconfig-push" "$CCD" | awk '{print $2}')
    [ -z "$FIXED_IP" ] && continue

    # Réécrire le CCD proprement
    TMPFILE=$(mktemp)
    echo "# Technicien : $CLIENT" > "$TMPFILE"
    echo "# Mis à jour le : $(date '+%Y-%m-%d %H:%M')" >> "$TMPFILE"
    echo "" >> "$TMPFILE"
    echo "ifconfig-push $FIXED_IP 255.255.255.0" >> "$TMPFILE"
    echo "" >> "$TMPFILE"
    echo "# Routes vers tous les sites :" >> "$TMPFILE"

    while IFS=',' read -r site vpn_net vpn_mask rest; do
        [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
        echo "push \"route $vpn_net $vpn_mask\"   # $site" >> "$TMPFILE"
    done < "$SITES_CSV"

    mv "$TMPFILE" "$CCD"
    echo "  CCD mis à jour : $CLIENT"
done
SCRIPT
chmod +x "$SCRIPTS_DIR/update-tech-ccd.sh"
success "Script update-tech-ccd.sh créé (remplace client-connect — plus robuste)"

progress "5/7 — Sauvegarde de l'IP serveur"
echo "$SERVER_IP" > /etc/openvpn/server_ip.txt
success "IP serveur sauvegardée : $SERVER_IP"

# ══════════════════════════════════════════════════════════════════════════════
# 6/7 — IPTABLES
# ══════════════════════════════════════════════════════════════════════════════
progress "6/7 — Activation du routage IP"
sed -i '/^#*net.ipv4.ip_forward/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
success "Routage IP activé (ip_forward=1)"

progress "6/7 — Règles iptables de base"
MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
step "Interface réseau principale détectée : $MAIN_IF"

# Flush
iptables -F FORWARD
iptables -t nat -F

# Politique par défaut : DROP sur FORWARD
iptables -P FORWARD DROP

# Connexions établies (retour des flux)
iptables -A FORWARD -m state --state ESTABLISHED,RELATED \
    -m comment --comment "retour-flux-etablis" -j ACCEPT

# NAT sortant vers internet
iptables -t nat -A POSTROUTING -o "$MAIN_IF" -j MASQUERADE

# NOTE : Les règles techniciens→sites sont ajoutées par nouveau-site.sh
# (une règle granulaire par site, pas une règle globale trop permissive)

netfilter-persistent save > /dev/null 2>&1
success "Règles iptables de base configurées (règles par site = ajoutées par nouveau-site.sh)"

# ══════════════════════════════════════════════════════════════════════════════
# 7/7 — SCRIPTS + DÉMARRAGE
# ══════════════════════════════════════════════════════════════════════════════
progress "7/7 — Installation des scripts de gestion"
SCRIPT_SRC="$(dirname "$(realpath "$0")")"
for script in nouveau-site.sh nouvel-utilisateur.sh; do
    if [ -f "$SCRIPT_SRC/$script" ]; then
        cp "$SCRIPT_SRC/$script" /usr/local/bin/
        chmod +x "/usr/local/bin/$script"
        success "  $script → /usr/local/bin/$script"
    else
        warn "  $script non trouvé dans $SCRIPT_SRC — à copier manuellement"
    fi
done

progress "7/7 — Activation et démarrage du service OpenVPN"
step "systemctl enable openvpn@server..."
systemctl enable openvpn@server > /dev/null 2>&1
success "Service activé au démarrage"

step "systemctl start openvpn@server..."
systemctl restart openvpn@server
ELAPSED=0
while [ $ELAPSED -lt 6 ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    echo -ne "\r  ${CYAN}[....] Démarrage en cours... ${ELAPSED}s${NC}  "
done
echo -ne "\r                                              \r"

if systemctl is-active --quiet openvpn@server; then
    success "Service OpenVPN démarré et actif"
    VPN_IP=$(ip a show tun0 2>/dev/null | grep "inet " | awk '{print $2}')
    [ -n "$VPN_IP" ] && success "Interface tun0 active : $VPN_IP"
else
    warn "Le service ne démarre pas — diagnostic :"
    journalctl -xeu openvpn@server --no-pager -n 5 2>/dev/null || true
    warn "Commande de diagnostic : sudo journalctl -xeu openvpn@server"
fi

# ══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║         Installation terminée ✓              ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}Fichiers importants :${NC}"
echo -e "  ${YELLOW}/etc/openvpn/server.conf${NC}              Config serveur"
echo -e "  ${YELLOW}/etc/openvpn/sites.csv${NC}                Registre des sites"
echo -e "  ${YELLOW}/etc/openvpn/ccd/${NC}                     Profils par client"
echo -e "  ${YELLOW}/etc/openvpn/scripts/update-tech-ccd.sh${NC} MAJ CCD techniciens"
echo -e "  ${YELLOW}$OVPN_CA/pki/${NC}             PKI complète"
echo -e "  ${YELLOW}/var/log/openvpn.log${NC}                  Journal"
echo ""
echo -e "${BOLD}Prochaines étapes :${NC}"
echo -e "  ${CYAN}sudo nouveau-site.sh${NC}         — Ajouter un premier site client"
echo -e "  ${CYAN}sudo nouvel-utilisateur.sh${NC}   — Créer un technicien"
echo ""
echo -e "${BOLD}Vérifications :${NC}"
echo -e "  ${CYAN}sudo systemctl status openvpn@server${NC}"
echo -e "  ${CYAN}sudo ss -ulnp | grep 1194${NC}"
echo -e "  ${CYAN}sudo cat /var/log/openvpn-status.log${NC}"
echo ""
echo -e "${BOLD}Test de validation après ajout d'un site :${NC}"
echo -e "  ${CYAN}# Sur le serveur, surveiller le trafic VPN${NC}"
echo -e "  ${CYAN}sudo tcpdump -ni tun0 -n${NC}"
echo -e "  ${CYAN}# Sur le mini-PC du site, surveiller le trafic LAN${NC}"
echo -e "  ${CYAN}sudo tcpdump -ni eth0 -n${NC}"
echo ""
