#!/bin/bash
# =============================================================================
# setup-iptables.sh — Configuration iptables sécurisée pour serveur VPN GTB
# Règles strictes : tout bloqué sauf VPN + SSH/SCP réseau local uniquement
# Usage : sudo bash setup-iptables.sh
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

step()    { echo -e "${CYAN}[....] $1${NC}"; }
success() { echo -e "${GREEN}[ OK ] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
error()   { echo -e "${RED}[FAIL] $1${NC}"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}";
            echo -e "${BOLD}${CYAN}  $1${NC}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}\n"; }

[ "$EUID" -ne 0 ] && error "Lancer avec sudo : sudo bash setup-iptables.sh"

SITES_CSV="/etc/openvpn/sites.csv"

header "Configuration iptables — Serveur VPN GTB/GTC"

# ── Détecter l'interface réseau principale ────────────────────────────────────
MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
[ -z "$MAIN_IF" ] && error "Interface réseau principale introuvable."
step "Interface réseau principale : $MAIN_IF"

# ── Détecter le réseau local ──────────────────────────────────────────────────
LOCAL_NET=$(ip -o -f inet addr show "$MAIN_IF" | awk '{print $4}' | head -1)
# Extraire le sous-réseau (ex: 192.168.1.0/24 depuis 192.168.1.10/24)
LOCAL_SUBNET=$(python3 -c "
import ipaddress
net = ipaddress.ip_interface('$LOCAL_NET').network
print(str(net))
" 2>/dev/null || ipcalc -n "$LOCAL_NET" 2>/dev/null | grep Network | awk '{print $2}')

[ -z "$LOCAL_SUBNET" ] && LOCAL_SUBNET="192.168.0.0/16" && \
    warn "Sous-réseau local non détecté — utilisation de $LOCAL_SUBNET par défaut"

step "Sous-réseau local détecté : $LOCAL_SUBNET"

echo ""
echo -e "${BOLD}Récapitulatif de la configuration :${NC}"
echo -e "  Interface principale : ${YELLOW}$MAIN_IF${NC}"
echo -e "  Réseau local         : ${YELLOW}$LOCAL_SUBNET${NC}"
echo -e "  SSH/SCP autorisé     : ${YELLOW}réseau local uniquement${NC}"
echo -e "  VPN OpenVPN          : ${YELLOW}UDP 1194 — ouvert internet${NC}"
echo -e "  Tout le reste        : ${RED}BLOQUÉ${NC}"
echo ""

# ── Avertissement SSH ─────────────────────────────────────────────────────────
echo -e "${RED}${BOLD}╔════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}║  ATTENTION — LECTURE OBLIGATOIRE                  ║${NC}"
echo -e "${RED}${BOLD}║                                                    ║${NC}"
echo -e "${RED}${BOLD}║  Si tu es connecté en SSH depuis l'EXTÉRIEUR       ║${NC}"
echo -e "${RED}${BOLD}║  (internet, pas réseau local), ta session SSH      ║${NC}"
echo -e "${RED}${BOLD}║  sera COUPÉE à l'application des règles.           ║${NC}"
echo -e "${RED}${BOLD}║                                                    ║${NC}"
echo -e "${RED}${BOLD}║  SSH depuis le réseau local ($LOCAL_SUBNET)  ║${NC}"
echo -e "${RED}${BOLD}║  restera fonctionnel.                              ║${NC}"
echo -e "${RED}${BOLD}╚════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "Tu confirmes être sur le réseau LOCAL ? [o/N] " CONFIRM
[[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé — aucune règle appliquée."; exit 0; }

echo ""
header "Application des règles iptables"

# ══════════════════════════════════════════════════════════════════════════════
# FLUSH — Remise à zéro complète
# ══════════════════════════════════════════════════════════════════════════════
step "Remise à zéro des règles existantes..."
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
success "Tables vidées"

# ══════════════════════════════════════════════════════════════════════════════
# POLITIQUES PAR DÉFAUT — Tout bloquer
# ══════════════════════════════════════════════════════════════════════════════
step "Politique par défaut : DROP sur INPUT, FORWARD, OUTPUT..."
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  ACCEPT   # On fait confiance au trafic sortant du serveur
success "Politiques par défaut configurées"

# ══════════════════════════════════════════════════════════════════════════════
# CHAÎNE INPUT — Ce qui peut entrer sur le serveur
# ══════════════════════════════════════════════════════════════════════════════
step "Règles INPUT..."

# Loopback (localhost)
iptables -A INPUT -i lo -j ACCEPT

# Connexions déjà établies (retour des flux sortants)
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# SSH — réseau local UNIQUEMENT
iptables -A INPUT -i "$MAIN_IF" -s "$LOCAL_SUBNET" -p tcp --dport 22 \
    -m state --state NEW \
    -m comment --comment "SSH-local-uniquement" \
    -j ACCEPT

# OpenVPN — port 1194 UDP — ouvert sur internet
iptables -A INPUT -i "$MAIN_IF" -p udp --dport 1194 \
    -m comment --comment "OpenVPN-internet" \
    -j ACCEPT

# Interface web (port 5000) — réseau local ET VPN uniquement
iptables -A INPUT -i "$MAIN_IF" -s "$LOCAL_SUBNET" -p tcp --dport 5000 \
    -m comment --comment "web-local" \
    -j ACCEPT
iptables -A INPUT -i tun0 -p tcp --dport 5000 \
    -m comment --comment "web-via-vpn" \
    -j ACCEPT

# Trafic VPN entrant (tunnel tun0)
iptables -A INPUT -i tun0 \
    -m comment --comment "trafic-vpn-interne" \
    -j ACCEPT

# ICMP ping — réseau local uniquement (pour diagnostic)
iptables -A INPUT -i "$MAIN_IF" -s "$LOCAL_SUBNET" -p icmp \
    -m comment --comment "ping-local" \
    -j ACCEPT

# Bloquer tout le reste sur INPUT (déjà bloqué par DROP mais explicite pour les logs)
iptables -A INPUT -m limit --limit 5/min -j LOG \
    --log-prefix "IPT-INPUT-DROP: " --log-level 4

success "Règles INPUT configurées"

# ══════════════════════════════════════════════════════════════════════════════
# CHAÎNE FORWARD — Routage entre interfaces
# ══════════════════════════════════════════════════════════════════════════════
step "Règles FORWARD..."

# Connexions déjà établies
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

# Techniciens → sites (une règle par site depuis sites.csv)
SITE_COUNT=0
if [ -f "$SITES_CSV" ]; then
    while IFS=',' read -r site vpn_net vpn_mask rest; do
        [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
        iptables -A FORWARD -i tun0 -s 10.10.0.0/24 -d "$vpn_net/24" \
            -m comment --comment "tech→$site" -j ACCEPT
        iptables -A FORWARD -i tun0 -s "$vpn_net/24" -d 10.10.0.0/8 \
            -m comment --comment "$site→autres-interdit" -j DROP
        SITE_COUNT=$((SITE_COUNT + 1))
        success "  Règles ajoutées pour $site ($vpn_net/24)"
    done < "$SITES_CSV"
fi

[ "$SITE_COUNT" -eq 0 ] && \
    warn "Aucun site dans sites.csv — les règles par site seront ajoutées par nouveau-site.sh"

# Bloquer tout FORWARD non autorisé (log + drop)
iptables -A FORWARD -m limit --limit 5/min -j LOG \
    --log-prefix "IPT-FORWARD-DROP: " --log-level 4

success "Règles FORWARD configurées ($SITE_COUNT site(s) traités)"

# ══════════════════════════════════════════════════════════════════════════════
# NAT — Masquerade pour le trafic sortant
# ══════════════════════════════════════════════════════════════════════════════
step "Règles NAT..."

# NAT sortant pour le trafic VPN vers internet
iptables -t nat -A POSTROUTING -s 10.10.0.0/8 -o "$MAIN_IF" -j MASQUERADE

success "NAT configuré"

# ══════════════════════════════════════════════════════════════════════════════
# ROUTAGE IP
# ══════════════════════════════════════════════════════════════════════════════
step "Activation du routage IP..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-vpn-forward.conf
sysctl -p /etc/sysctl.d/99-vpn-forward.conf > /dev/null 2>&1
success "Routage IP activé"

# ══════════════════════════════════════════════════════════════════════════════
# SAUVEGARDE — Persistance après reboot
# ══════════════════════════════════════════════════════════════════════════════
step "Sauvegarde des règles (persistance au reboot)..."

# S'assurer que iptables-persistent est installé
if ! command -v netfilter-persistent > /dev/null 2>&1; then
    warn "iptables-persistent non installé — installation..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1
fi

netfilter-persistent save > /dev/null 2>&1
success "Règles sauvegardées dans /etc/iptables/rules.v4"

# ══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ
# ══════════════════════════════════════════════════════════════════════════════
header "Configuration terminée ✓"

echo -e "${BOLD}Règles actives :${NC}"
echo ""
iptables -L INPUT -n --line-numbers | while IFS= read -r line; do
    if echo "$line" | grep -q "ACCEPT"; then
        echo -e "  ${GREEN}$line${NC}"
    elif echo "$line" | grep -q "DROP\|REJECT"; then
        echo -e "  ${RED}$line${NC}"
    else
        echo "  $line"
    fi
done

echo ""
echo -e "${BOLD}FORWARD :${NC}"
iptables -L FORWARD -n --line-numbers | while IFS= read -r line; do
    if echo "$line" | grep -q "ACCEPT"; then
        echo -e "  ${GREEN}$line${NC}"
    elif echo "$line" | grep -q "DROP\|REJECT"; then
        echo -e "  ${RED}$line${NC}"
    else
        echo "  $line"
    fi
done

echo ""
echo -e "${BOLD}NAT :${NC}"
iptables -t nat -L POSTROUTING -n | while IFS= read -r line; do
    echo "  $line"
done

echo ""
echo -e "${GREEN}${BOLD}✓ Serveur sécurisé${NC}"
echo ""
echo -e "${BOLD}Ce qui est autorisé :${NC}"
echo -e "  ${GREEN}✓${NC} SSH/SCP          : réseau local ($LOCAL_SUBNET) uniquement"
echo -e "  ${GREEN}✓${NC} OpenVPN          : UDP 1194 — internet"
echo -e "  ${GREEN}✓${NC} Interface web    : port 5000 — local + via VPN"
echo -e "  ${GREEN}✓${NC} Ping             : réseau local uniquement"
echo -e "  ${RED}✗${NC} Tout le reste    : BLOQUÉ"
echo ""
echo -e "${BOLD}Vérification :${NC}"
echo -e "  ${CYAN}sudo iptables -L -n --line-numbers${NC}"
echo -e "  ${CYAN}sudo iptables -L -n -t nat${NC}"
echo ""
