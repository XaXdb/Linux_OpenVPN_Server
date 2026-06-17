#!/bin/bash
# =============================================================================
# install-web.sh — Installation de l'interface web VPN GTB/GTC
# Usage : sudo bash install-web.sh
# =============================================================================

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()    { echo -e "${CYAN}[....] $1${NC}"; }
success() { echo -e "${GREEN}[ OK ] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
error()   { echo -e "${RED}[FAIL] $1${NC}"; exit 1; }

[ "$EUID" -ne 0 ] && error "Lancer avec sudo"

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
WEB_DIR="$SCRIPT_DIR/web"
INSTALL_DIR="/opt/vpn-gtb-web"

echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Installation Interface Web VPN GTB    ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Python et Flask ───────────────────────────────────────────────────────────
step "Installation de Python3 et pip..."
apt-get install -y python3 python3-pip python3-venv > /dev/null 2>&1
success "Python3 installé"

step "Copie des fichiers web dans $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp -r "$WEB_DIR"/* "$INSTALL_DIR/"
success "Fichiers copiés"

step "Création de l'environnement virtuel Python..."
python3 -m venv "$INSTALL_DIR/venv" > /dev/null 2>&1
success "Environnement virtuel créé"

step "Installation de Flask..."
"$INSTALL_DIR/venv/bin/pip" install flask --quiet
success "Flask installé"

# ── Secret key aléatoire ──────────────────────────────────────────────────────
step "Génération de la clé secrète..."
SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/changeme-avant-production/$SECRET/" "$INSTALL_DIR/app.py"
success "Clé secrète configurée"

# ── Sudo sans mot de passe pour les scripts ───────────────────────────────────
step "Configuration sudo pour les scripts VPN..."
cat > /etc/sudoers.d/vpn-web <<'EOF'
# Permet à l'interface web d'exécuter les scripts VPN sans mot de passe
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/nouveau-site.sh
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/nouvel-utilisateur.sh
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/revoquer-utilisateur.sh
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/supprimer-site.sh
www-data ALL=(ALL) NOPASSWD: /usr/local/bin/update-tech-ccd.sh
EOF
chmod 440 /etc/sudoers.d/vpn-web
success "Règles sudo configurées"

# ── Service systemd ───────────────────────────────────────────────────────────
step "Création du service systemd..."
cat > /etc/systemd/system/vpn-gtb-web.service <<EOF
[Unit]
Description=VPN GTB/GTC — Interface Web
After=network.target openvpn@server.service

[Service]
Type=simple
User=www-data
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python3 $INSTALL_DIR/app.py
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpn-gtb-web > /dev/null 2>&1
systemctl restart vpn-gtb-web
sleep 2

if systemctl is-active --quiet vpn-gtb-web; then
    success "Service web démarré"
else
    warn "Le service ne démarre pas — vérifier : sudo journalctl -u vpn-gtb-web"
fi

# ── Résumé ────────────────────────────────────────────────────────────────────
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}${BOLD}✓ Interface web installée${NC}"
echo ""
echo -e "${BOLD}Accès depuis le réseau local :${NC}"
echo -e "  ${CYAN}http://${LOCAL_IP}:5000${NC}"
echo ""
echo -e "${BOLD}Identifiants par défaut :${NC}"
echo -e "  Login    : ${YELLOW}admin${NC}"
echo -e "  Password : ${YELLOW}vpn-gtb-2026${NC}"
echo -e "  ${RED}→ Modifier dans $INSTALL_DIR/app.py (variable USERS)${NC}"
echo ""
echo -e "${BOLD}Commandes utiles :${NC}"
echo -e "  ${CYAN}sudo systemctl status vpn-gtb-web${NC}"
echo -e "  ${CYAN}sudo journalctl -u vpn-gtb-web -f${NC}"
echo ""
