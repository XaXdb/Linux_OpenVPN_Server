#!/bin/bash
# =============================================================================
# status.sh — Tableau de bord temps réel du serveur OpenVPN GTB/GTC
# Usage : sudo status.sh  ou  sudo status.sh --watch (rafraîchissement auto)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
MAGENTA='\033[0;35m'; DIM='\033[2m'; NC='\033[0m'

SITES_CSV="/etc/openvpn/sites.csv"
CCD_DIR="/etc/openvpn/ccd"
STATUS_LOG="/var/log/openvpn-status.log"
OPENVPN_LOG="/var/log/openvpn.log"
OVPN_CA="$(find /home -maxdepth 2 -name "openvpn-ca" -type d 2>/dev/null | head -1)"
[ -z "$OVPN_CA" ] && OVPN_CA="/root/openvpn-ca"

# ── Helpers ───────────────────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
sep()  { echo -e "${DIM}  ────────────────────────────────────────────────────${NC}"; }

check_root() {
    [ "$EUID" -ne 0 ] && echo -e "${YELLOW}[WARN] Lancer avec sudo pour les infos complètes${NC}" && echo ""
}

# ── Bloc : En-tête ────────────────────────────────────────────────────────────
print_header() {
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║        Tableau de bord VPN GTB/GTC                  ║"
    echo "  ║        $NOW                       ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Bloc : Service OpenVPN ────────────────────────────────────────────────────
print_service() {
    echo -e "${BOLD}${BLUE}▶ SERVICE OPENVPN${NC}"
    sep

    if systemctl is-active --quiet openvpn@server 2>/dev/null; then
        ok "${BOLD}${GREEN}Service : ACTIF${NC}"
        UPTIME=$(systemctl show openvpn@server --property=ActiveEnterTimestamp \
            | cut -d= -f2)
        ok "Démarré le : $UPTIME"
    else
        fail "${BOLD}${RED}Service : INACTIF ou EN ERREUR${NC}"
        echo ""
        echo -e "  ${RED}Dernières lignes du journal :${NC}"
        journalctl -u openvpn@server --no-pager -n 5 2>/dev/null | \
            while IFS= read -r line; do echo "    $line"; done
    fi

    # Interface tun0
    if ip link show tun0 > /dev/null 2>&1; then
        TUN_IP=$(ip a show tun0 | grep "inet " | awk '{print $2}')
        ok "Interface tun0 : ${CYAN}$TUN_IP${NC}"
    else
        fail "Interface tun0 : absente"
    fi

    # Port UDP 1194
    if ss -ulnp 2>/dev/null | grep -q ":1194 "; then
        ok "Port UDP 1194  : ${GREEN}en écoute${NC}"
    else
        fail "Port UDP 1194  : ${RED}fermé${NC}"
    fi

    # Routage IP
    IP_FWD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [ "$IP_FWD" = "1" ]; then
        ok "Routage IP     : ${GREEN}activé${NC}"
    else
        fail "Routage IP     : ${RED}désactivé${NC} (ip_forward=0)"
    fi

    echo ""
}

# ── Bloc : CRL ────────────────────────────────────────────────────────────────
print_crl() {
    echo -e "${BOLD}${BLUE}▶ CERTIFICAT / CRL${NC}"
    sep

    if [ -f "/etc/openvpn/crl.pem" ]; then
        NEXT_UPDATE=$(openssl crl -in /etc/openvpn/crl.pem -noout -nextupdate 2>/dev/null \
            | cut -d= -f2)
        # Calculer les jours restants
        NEXT_TS=$(date -d "$NEXT_UPDATE" +%s 2>/dev/null || echo 0)
        NOW_TS=$(date +%s)
        DAYS_LEFT=$(( (NEXT_TS - NOW_TS) / 86400 ))

        if [ "$DAYS_LEFT" -gt 30 ]; then
            ok "CRL expire dans : ${GREEN}$DAYS_LEFT jours${NC} ($NEXT_UPDATE)"
        elif [ "$DAYS_LEFT" -gt 7 ]; then
            warn "CRL expire dans : ${YELLOW}$DAYS_LEFT jours${NC} — renouvellement conseillé"
        else
            fail "CRL expire dans : ${RED}$DAYS_LEFT jours${NC} — RENOUVELLEMENT URGENT"
            echo -e "  ${RED}→ cd ~/openvpn-ca && ./easyrsa gen-crl && sudo cp pki/crl.pem /etc/openvpn/${NC}"
        fi

        # Nombre de révocations
        REVOKED=$(openssl crl -in /etc/openvpn/crl.pem -noout -text 2>/dev/null \
            | grep -c "Serial Number" || echo 0)
        ok "Certificats révoqués : $REVOKED"
    else
        fail "CRL introuvable : /etc/openvpn/crl.pem"
    fi

    echo ""
}

# ── Bloc : Clients connectés ──────────────────────────────────────────────────
print_connected() {
    echo -e "${BOLD}${BLUE}▶ CLIENTS CONNECTÉS${NC}"
    sep

    if [ ! -f "$STATUS_LOG" ]; then
        warn "Fichier status introuvable : $STATUS_LOG"
        echo ""
        return
    fi

    # Parser le fichier status OpenVPN
    # Format : Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since
    CONNECTED=()
    IN_CLIENT_SECTION=0

    while IFS= read -r line; do
        if [[ "$line" == "Common Name"* ]]; then
            IN_CLIENT_SECTION=1
            continue
        fi
        if [[ "$line" == "ROUTING TABLE"* ]] || [[ "$line" == "OpenVPN CLIENT LIST"* ]]; then
            IN_CLIENT_SECTION=0
            continue
        fi
        if [ "$IN_CLIENT_SECTION" = "1" ] && [ -n "$line" ]; then
            CONNECTED+=("$line")
        fi
    done < "$STATUS_LOG"

    if [ ${#CONNECTED[@]} -eq 0 ]; then
        warn "Aucun client connecté actuellement"
    else
        echo -e "  ${BOLD}$(printf '%-22s %-20s %-16s %-20s' 'Nom' 'IP publique' 'IP VPN' 'Connecté depuis')${NC}"
        echo -e "  ${DIM}$(printf '%-22s %-20s %-16s %-20s' '──────────────────────' '────────────────────' '────────────────' '────────────────────')${NC}"

        for entry in "${CONNECTED[@]}"; do
            CN=$(echo "$entry" | cut -d',' -f1)
            REAL_ADDR=$(echo "$entry" | cut -d',' -f2)
            SINCE=$(echo "$entry" | cut -d',' -f5)
            BYTES_RX=$(echo "$entry" | cut -d',' -f3)
            BYTES_TX=$(echo "$entry" | cut -d',' -f4)

            # Récupérer l'IP VPN depuis le fichier routing
            VPN_IP=$(grep "^$CN," "$STATUS_LOG" 2>/dev/null | head -1 | cut -d',' -f2 || echo "?")

            # Icône selon le type
            if [[ "$CN" == tech-* ]]; then
                ICON="${CYAN}[TECH]${NC}"
            elif [[ "$CN" == temp-* ]]; then
                ICON="${YELLOW}[TEMP]${NC}"
            elif [[ "$CN" == site-* ]]; then
                ICON="${GREEN}[SITE]${NC}"
            else
                ICON="${DIM}[????]${NC}"
            fi

            # Formater les octets
            RX_MB=$(echo "scale=1; $BYTES_RX / 1048576" | bc 2>/dev/null || echo "?")
            TX_MB=$(echo "scale=1; $BYTES_TX / 1048576" | bc 2>/dev/null || echo "?")

            echo -e "  $ICON $(printf '%-18s' "$CN") $(printf '%-20s' "$REAL_ADDR") $(printf '%-16s' "$VPN_IP") $SINCE"
            echo -e "      ${DIM}↓ ${RX_MB} MB  ↑ ${TX_MB} MB${NC}"
        done
    fi

    echo ""
}

# ── Bloc : Sites configurés ───────────────────────────────────────────────────
print_sites() {
    echo -e "${BOLD}${BLUE}▶ SITES CLIENTS${NC}"
    sep

    if [ ! -f "$SITES_CSV" ] || ! grep -q "^[^#]" "$SITES_CSV" 2>/dev/null; then
        warn "Aucun site configuré (sites.csv vide)"
        echo ""
        return
    fi

    # Lire les clients actuellement connectés pour le statut en ligne
    ONLINE_CLIENTS=""
    [ -f "$STATUS_LOG" ] && ONLINE_CLIENTS=$(grep -E "^site-" "$STATUS_LOG" 2>/dev/null | cut -d',' -f1 || true)

    echo -e "  ${BOLD}$(printf '%-18s %-16s %-16s %-8s' 'Site' 'Réseau VPN' 'Réseau physique' 'Statut')${NC}"
    echo -e "  ${DIM}$(printf '%-18s %-16s %-16s %-8s' '──────────────────' '────────────────' '────────────────' '────────')${NC}"

    TOTAL=0
    ONLINE=0

    while IFS=',' read -r site vpn_net vpn_mask phys_net phys_mask; do
        [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
        TOTAL=$((TOTAL + 1))

        if echo "$ONLINE_CLIENTS" | grep -q "^$site$"; then
            STATUS="${GREEN}● EN LIGNE${NC}"
            ONLINE=$((ONLINE + 1))
        else
            STATUS="${RED}○ hors ligne${NC}"
        fi

        echo -e "  $(printf '%-18s' "$site") $(printf '%-16s' "$vpn_net/24") $(printf '%-16s' "$phys_net/24") $STATUS"
    done < "$SITES_CSV"

    echo ""
    echo -e "  Total sites : ${BOLD}$TOTAL${NC}  |  En ligne : ${GREEN}${BOLD}$ONLINE${NC}  |  Hors ligne : ${RED}$((TOTAL - ONLINE))${NC}"
    echo ""
}

# ── Bloc : Utilisateurs (tech + temp) ────────────────────────────────────────
print_users() {
    echo -e "${BOLD}${BLUE}▶ UTILISATEURS (TECHNICIENS & TEMPORAIRES)${NC}"
    sep

    ONLINE_CLIENTS=""
    [ -f "$STATUS_LOG" ] && ONLINE_CLIENTS=$(cat "$STATUS_LOG" 2>/dev/null || true)

    TECH_TOTAL=0; TECH_ONLINE=0
    TEMP_TOTAL=0; TEMP_ONLINE=0

    echo -e "  ${BOLD}$(printf '%-22s %-12s %-16s %-10s %-12s' 'Nom' 'Type' 'IP VPN' 'Statut' 'Expire')${NC}"
    echo -e "  ${DIM}$(printf '%-22s %-12s %-16s %-10s %-12s' '──────────────────────' '────────────' '────────────────' '──────────' '────────────')${NC}"

    for CCD in "$CCD_DIR"/tech-* "$CCD_DIR"/temp-*; do
        [ -f "$CCD" ] || continue
        NAME=$(basename "$CCD")
        IP=$(grep "ifconfig-push" "$CCD" 2>/dev/null | awk '{print $2}' || echo "?")
        EXPIRE=$(grep "Expire" "$CCD" 2>/dev/null | awk '{print $NF}' || echo "?")

        if [[ "$NAME" == tech-* ]]; then
            TYPE="${CYAN}technicien${NC}"
            TECH_TOTAL=$((TECH_TOTAL + 1))
        else
            TYPE="${YELLOW}temporaire${NC}"
            TEMP_TOTAL=$((TEMP_TOTAL + 1))

            # Vérifier si le cert temporaire est expiré
            if [ -f "$OVPN_CA/pki/issued/$NAME.crt" ]; then
                END_DATE=$(openssl x509 -in "$OVPN_CA/pki/issued/$NAME.crt" \
                    -noout -enddate 2>/dev/null | cut -d= -f2)
                END_TS=$(date -d "$END_DATE" +%s 2>/dev/null || echo 0)
                NOW_TS=$(date +%s)
                DAYS=$((( END_TS - NOW_TS ) / 86400))
                if [ "$DAYS" -lt 0 ]; then
                    EXPIRE="${RED}EXPIRÉ${NC}"
                elif [ "$DAYS" -lt 3 ]; then
                    EXPIRE="${RED}${DAYS}j${NC}"
                elif [ "$DAYS" -lt 7 ]; then
                    EXPIRE="${YELLOW}${DAYS}j${NC}"
                else
                    EXPIRE="${GREEN}${DAYS}j${NC}"
                fi
            fi
        fi

        # Statut en ligne
        if echo "$ONLINE_CLIENTS" | grep -q "^$NAME,"; then
            STATUS="${GREEN}● connecté${NC}"
            [[ "$NAME" == tech-* ]] && TECH_ONLINE=$((TECH_ONLINE + 1)) || TEMP_ONLINE=$((TEMP_ONLINE + 1))
        else
            STATUS="${DIM}○ absent${NC}"
        fi

        echo -e "  $(printf '%-22s' "$NAME") $TYPE    $(printf '%-16s' "$IP") $STATUS   $EXPIRE"
    done

    if [ "$TECH_TOTAL" -eq 0 ] && [ "$TEMP_TOTAL" -eq 0 ]; then
        warn "Aucun utilisateur configuré"
    else
        echo ""
        echo -e "  Techniciens : ${BOLD}$TECH_TOTAL${NC} (${GREEN}$TECH_ONLINE connecté(s)${NC})  |  Temporaires : ${BOLD}$TEMP_TOTAL${NC} (${GREEN}$TEMP_ONLINE connecté(s)${NC})"
    fi
    echo ""
}

# ── Bloc : iptables ───────────────────────────────────────────────────────────
print_iptables() {
    echo -e "${BOLD}${BLUE}▶ RÈGLES IPTABLES (FORWARD)${NC}"
    sep

    COUNT=$(iptables -L FORWARD --line-numbers -n 2>/dev/null | grep -c "tun0" || echo 0)
    if [ "$COUNT" -gt 0 ]; then
        ok "$COUNT règle(s) active(s) sur la chaîne FORWARD"
        echo ""
        iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -E "tun0|ACCEPT|DROP" | \
        while IFS= read -r line; do
            if echo "$line" | grep -q "ACCEPT"; then
                echo -e "    ${GREEN}$line${NC}"
            elif echo "$line" | grep -q "DROP"; then
                echo -e "    ${RED}$line${NC}"
            else
                echo "    $line"
            fi
        done
    else
        warn "Aucune règle iptables sur tun0 — vérifier la configuration"
    fi
    echo ""
}

# ── Bloc : Dernières lignes de log ────────────────────────────────────────────
print_logs() {
    echo -e "${BOLD}${BLUE}▶ JOURNAL (10 dernières lignes)${NC}"
    sep

    if [ -f "$OPENVPN_LOG" ]; then
        tail -10 "$OPENVPN_LOG" | while IFS= read -r line; do
            if echo "$line" | grep -qiE "error|fail|FAIL"; then
                echo -e "  ${RED}$line${NC}"
            elif echo "$line" | grep -qiE "warning|warn"; then
                echo -e "  ${YELLOW}$line${NC}"
            elif echo "$line" | grep -qiE "completed|connected|Sequence"; then
                echo -e "  ${GREEN}$line${NC}"
            else
                echo -e "  ${DIM}$line${NC}"
            fi
        done
    else
        warn "Journal introuvable : $OPENVPN_LOG"
    fi
    echo ""
}

# ── Bloc : Pied de page ───────────────────────────────────────────────────────
print_footer() {
    sep
    echo -e "  ${DIM}Commandes utiles :${NC}"
    echo -e "  ${CYAN}sudo nouveau-site.sh${NC}          Ajouter un site"
    echo -e "  ${CYAN}sudo nouvel-utilisateur.sh${NC}    Créer un utilisateur"
    echo -e "  ${CYAN}sudo revoquer-utilisateur.sh${NC}  Révoquer un utilisateur"
    echo -e "  ${CYAN}sudo supprimer-site.sh${NC}        Supprimer un site"
    echo -e "  ${CYAN}sudo status.sh --watch${NC}        Rafraîchissement automatique (5s)"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
run_once() {
    check_root
    print_header
    print_service
    print_crl
    print_sites
    print_users
    print_connected
    print_iptables
    print_logs
    print_footer
}

if [ "$1" = "--watch" ] || [ "$1" = "-w" ]; then
    echo -e "${CYAN}Mode watch activé — rafraîchissement toutes les 5 secondes (Ctrl+C pour quitter)${NC}"
    sleep 1
    while true; do
        run_once
        sleep 5
    done
else
    run_once
fi
