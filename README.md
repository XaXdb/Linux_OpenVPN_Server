# Guide VPN OpenVPN — Infrastructure GTB/GTC

**Version** : 2.0 — Juin 2026  
**Compatibilité** : Ubuntu 22/24 LTS · Debian 11/12 · Raspberry Pi OS  
@xaxdb

---

## Table des matières

1. [Architecture](#1-architecture)
2. [Prérequis](#2-prérequis)
3. [Installation rapide](#3-installation-rapide)
4. [Installation manuelle étape par étape](#4-installation-manuelle-étape-par-étape)
5. [Ajouter un site client](#5-ajouter-un-site-client)
6. [Créer un utilisateur](#6-créer-un-utilisateur)
7. [Déploiement sur le mini-PC du site](#7-déploiement-sur-le-mini-pc-du-site)
8. [Révoquer un accès](#8-révoquer-un-accès)
9. [Maintenance](#9-maintenance)
10. [Dépannage](#10-dépannage)
11. [Référence des commandes](#11-référence-des-commandes)

---

## 1. Architecture

### Schéma global

```
                          INTERNET
                              │
                   ┌──────────┴──────────┐
                   │  Serveur OpenVPN    │
                   │  (Raspberry Pi /    │
                   │   Ubuntu / Debian)  │
                   │  IP publique fixe   │
                   │  IP VPN : 10.10.0.1 │
                   └──────────┬──────────┘
                              │  Tunnels VPN chiffrés (UDP 1194)
              ┌───────────────┼───────────────┐
              │               │               │
      ┌───────┴──────┐ ┌──────┴──────┐ ┌──────┴─────────┐
      │ Mini-PC      │ │ Mini-PC     │ │  PC Technicien │
      │ Site A       │ │ Site B      │ │   (partout)    │
      │ 10.10.1.1    │ │ 10.10.2.1   │ │   10.10.0.20+  │
      └───────┬──────┘ └──────┬──────┘ └────────────────┘
              │ NAT 1:1       │ NAT 1:1
      ┌───────┴──────┐ ┌──────┴──────┐
      │ 192.168.1.x  │ │ 192.168.1.x │  ← Mêmes plages IP physiques,
      │ JACE, automat│ │JACE, automat│   pas de conflit grâce au NAT
      └──────────────┘ └─────────────┘
```

### Plan d'adressage VPN

| Plage | Usage |
|-------|-------|
| `10.10.0.1` | Serveur OpenVPN |
| `10.10.0.20 – 10.10.0.69` | Techniciens (50 max) |
| `10.10.0.100 – 10.10.0.149` | Comptes temporaires (50 max) |
| `10.10.1.0/24` | Site 1 |
| `10.10.2.0/24` | Site 2 |
| `10.10.N.0/24` | Site N |

### Pourquoi le NAT 1:1 est indispensable

Plusieurs sites peuvent avoir le même réseau physique (`192.168.1.0/24`).
Le NAT 1:1 sur chaque mini-PC traduit les adresses :

```
Technicien tape : 10.10.1.32  →  Mini-PC Site A  →  NAT  →  192.168.1.32 (JACE)
Technicien tape : 10.10.2.32  →  Mini-PC Site B  →  NAT  →  192.168.1.32 (même IP, site différent)
```

Le technicien utilise **toujours l'adresse VPN** du site, jamais l'adresse physique.

### Règles d'isolation

| De | Vers | Règle |
|----|------|-------|
| Technicien | Tous les sites | ✅ Autorisé |
| Site A | Site B | ❌ Bloqué (iptables) |
| Site B | Site A | ❌ Bloqué (iptables) |
| Temporaire | Sites définis | ✅ Autorisé |
| Temporaire | Autres sites | ❌ Bloqué |

---

## 2. Prérequis

### Serveur (Raspberry Pi / VM / Serveur dédié)

- OS : Ubuntu 22/24 LTS, Debian 11/12, ou Raspberry Pi OS
- Accès root (sudo)
- Connexion internet
- **Port UDP 1194 ouvert** dans le pare-feu/box internet (redirection de port)
- IP publique fixe recommandée — sinon utiliser un DNS dynamique (No-IP, DynDNS)

### Sur chaque site client

- Mini-PC Linux (Ubuntu/Debian recommandé) ou Windows
- Connecté au réseau local du site
- Accès internet (UDP 1194 sortant — généralement ouvert par défaut)
- Allumé en permanence

---

## 3. Installation rapide

```bash
# Cloner ou copier les fichiers sur le serveur
cd ~
git clone <url-du-repo> vpn-gtb || cp -r /chemin/vers/vpn-gtb ~/

cd ~/vpn-gtb
chmod +x install.sh nouveau-site.sh nouvel-utilisateur.sh

# Lancer l'installation (répond aux questions interactives)
sudo bash install.sh
```

L'installation prend environ 3 à 5 minutes. À la fin, les commandes `nouveau-site.sh` et `nouvel-utilisateur.sh` sont disponibles directement.

---

## 4. Installation manuelle étape par étape

> Suivre cette section uniquement si vous n'utilisez pas `install.sh`.

### 4.1 Préparation du système

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install openvpn easy-rsa iptables-persistent curl -y

# Activer le routage IP
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Ouvrir le port VPN
sudo ufw allow 1194/udp
sudo ufw allow OpenSSH
sudo ufw enable
```

### 4.2 Création de la PKI

```bash
make-cadir ~/openvpn-ca
cd ~/openvpn-ca

# Éditer les variables
nano vars
# Ajouter :
# set_var EASYRSA_REQ_COUNTRY    "FR"
# set_var EASYRSA_REQ_PROVINCE   "Rhone-Alpes"
# set_var EASYRSA_REQ_CITY       "Lyon"
# set_var EASYRSA_REQ_ORG        "MonEntreprise"
# set_var EASYRSA_REQ_EMAIL      "admin@monentreprise.fr"
# set_var EASYRSA_REQ_OU         "GTB"
# set_var EASYRSA_CA_EXPIRE      3650
# set_var EASYRSA_CERT_EXPIRE    825

./easyrsa init-pki
./easyrsa build-ca nopass    # Appuyer sur Entrée pour le Common Name
```

### 4.3 Certificats serveur

```bash
cd ~/openvpn-ca
./easyrsa gen-req serveur nopass
./easyrsa sign-req server serveur    # Taper "yes"
./easyrsa gen-dh                     # 1-2 minutes
openvpn --genkey secret ta.key
./easyrsa gen-crl

# Copier dans /etc/openvpn/
sudo cp pki/ca.crt pki/issued/serveur.crt pki/private/serveur.key \
        pki/dh.pem ta.key pki/crl.pem /etc/openvpn/
sudo chmod 600 /etc/openvpn/serveur.key /etc/openvpn/ta.key
sudo chmod 644 /etc/openvpn/crl.pem
```

### 4.4 Configuration du serveur

```bash
sudo mkdir -p /etc/openvpn/ccd /etc/openvpn/scripts
sudo nano /etc/openvpn/server.conf
```

Contenu :

```
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

server 10.10.0.0 255.255.0.0
topology subnet

client-config-dir /etc/openvpn/ccd
client-connect    /etc/openvpn/scripts/client-connect.sh

# client-to-client   ← LAISSER COMMENTÉ (isolation gérée par iptables)

crl-verify /etc/openvpn/crl.pem

keepalive 10 120
persist-key
persist-tun
user  nobody
group nogroup

log-append /var/log/openvpn.log
status     /var/log/openvpn-status.log
verb 3
```

### 4.5 Script client-connect

```bash
sudo nano /etc/openvpn/scripts/client-connect.sh
```

```bash
#!/bin/bash
CLIENT="$common_name"
CCD="/etc/openvpn/ccd/$CLIENT"
SITES_CSV="/etc/openvpn/sites.csv"

if [[ "$CLIENT" == tech-* ]]; then
    FIXED_IP=$(grep "ifconfig-push" "$CCD" 2>/dev/null | awk '{print $2}')
    [ -z "$FIXED_IP" ] && exit 0
    echo "ifconfig-push $FIXED_IP 10.10.0.1" > "$CCD"
    while IFS=',' read -r site vpn_net vpn_mask phys_net phys_mask; do
        [[ "$site" =~ ^#.*$ || -z "$site" ]] && continue
        echo "push \"route $vpn_net $vpn_mask\"" >> "$CCD"
    done < "$SITES_CSV"
fi
exit 0
```

```bash
sudo chmod +x /etc/openvpn/scripts/client-connect.sh
touch /etc/openvpn/sites.csv
```

### 4.6 Règles iptables

```bash
MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)

iptables -P FORWARD DROP
iptables -A FORWARD -i tun0 -s 10.10.0.0/24 -d 10.10.0.0/16 -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -o $MAIN_IF -j MASQUERADE

# Sauvegarder
sudo netfilter-persistent save
```

### 4.7 Démarrage

```bash
sudo systemctl enable openvpn@server
sudo systemctl start openvpn@server
sudo systemctl status openvpn@server
```

---

## 5. Ajouter un site client

```bash
sudo nouveau-site.sh
```

Le script demande interactivement :
- Nom du site (ex: `site-dupont`)
- Réseau physique du site (ex: `192.168.1.0`)
- Masque réseau (ex: `255.255.255.0`)

Il génère automatiquement :
- Le certificat du site
- Le fichier CCD avec les règles d'isolation
- La route dans `server.conf`
- Les règles iptables
- Le fichier `.ovpn` à déployer sur le mini-PC

---

## 6. Créer un utilisateur

```bash
sudo nouvel-utilisateur.sh
```

### Technicien (accès permanent à tous les sites)

- Accès automatiquement mis à jour à chaque nouveau site
- Certificat valable 825 jours par défaut
- Fichier `.ovpn` à transmettre une seule fois

### Compte temporaire (accès limité)

- Accès uniquement aux sites choisis lors de la création
- Durée configurable (7, 30, 90 jours...)
- Expiration automatique sans intervention

---

## 7. Déploiement sur le mini-PC du site

### Mini-PC Linux (recommandé)

```bash
# Installer OpenVPN
sudo apt install openvpn iptables-persistent -y

# Copier le fichier .ovpn (transféré depuis le serveur)
sudo cp site-nom.ovpn /etc/openvpn/client.conf

# Activer le service au démarrage
sudo systemctl enable openvpn@client
sudo systemctl start openvpn@client

# Activer le routage IP
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# NAT 1:1 (adapter les réseaux selon le site)
# Exemple : VPN 10.10.1.0/24 ↔ Physique 192.168.1.0/24
sudo iptables -t nat -A PREROUTING  -d 10.10.1.0/24 -j NETMAP --to 192.168.1.0/24
sudo iptables -t nat -A POSTROUTING -s 192.168.1.0/24 -j NETMAP --to 10.10.1.0/24
sudo netfilter-persistent save
```

### Mini-PC Windows

```powershell
# Installer OpenVPN Community depuis https://openvpn.net/community-downloads/
# Copier le .ovpn dans : C:\Program Files\OpenVPN\config\

# Activer le service automatique (PowerShell admin)
Set-Service -Name "OpenVPNService" -StartupType Automatic
Start-Service -Name "OpenVPNService"

# Activer le routage IP (nécessite redémarrage)
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" `
  -Name "IPEnableRouter" -Value 1

# NAT
New-NetNat -Name "VPN-NAT" -InternalIPInterfaceAddressPrefix "192.168.1.0/24"
route add 10.10.0.0 MASK 255.255.0.0 0.0.0.0 -p
```

> **Note** : Le NAT Windows est moins fiable que Linux. Préférer un mini-PC sous Debian/Ubuntu.

---

## 8. Révoquer un accès

```bash
cd ~/openvpn-ca

# Révoquer le certificat
./easyrsa revoke nom-du-compte

# Mettre à jour la CRL
./easyrsa gen-crl
sudo cp pki/crl.pem /etc/openvpn/
```

La révocation est immédiate — pas besoin de redémarrer OpenVPN.

---

## 9. Maintenance

### Renouvellement automatique de la CRL

La CRL expire après 180 jours. Si elle expire, **toutes les connexions sont bloquées**.
Automatiser son renouvellement :

```bash
crontab -e
# Ajouter :
0 3 1 */3 * cd ~/openvpn-ca && ./easyrsa gen-crl && sudo cp pki/crl.pem /etc/openvpn/crl.pem
```

### Vérifier la date d'expiration de la CRL

```bash
sudo openssl crl -in /etc/openvpn/crl.pem -noout -nextupdate
```

### Voir les clients connectés

```bash
sudo cat /var/log/openvpn-status.log
```

### Mettre à jour les routes d'un technicien existant

Les routes sont injectées dynamiquement à chaque connexion via `client-connect.sh`.
Aucune action requise — à la prochaine reconnexion du technicien, les nouveaux sites apparaissent automatiquement.

---

## 10. Dépannage

| Symptôme | Commande | Cause probable |
|----------|----------|----------------|
| Service ne démarre pas | `sudo journalctl -xeu openvpn@server` | Fichier manquant, CRL expirée |
| Erreur "key mismatch" | `sudo cat /var/log/openvpn.log` | Certificat et clé de PKI différentes |
| Port 1194 non ouvert | `sudo ss -ulnp \| grep 1194` | Service non démarré |
| Client ne se connecte pas | `sudo tail -f /var/log/openvpn.log` | Certificat révoqué, mauvaise IP |
| Tunnel OK mais pas d'accès | `ping 10.10.1.1` | NAT non configuré sur le mini-PC |
| Tout bloqué soudainement | `openssl crl -in /etc/openvpn/crl.pem -noout -nextupdate` | CRL expirée |

### Vérifications de base

```bash
# 1. Service actif ?
sudo systemctl status openvpn@server

# 2. Port ouvert ?
sudo ss -ulnp | grep 1194

# 3. Interface tun0 présente ?
ip a show tun0

# 4. Logs en direct
sudo tail -f /var/log/openvpn.log

# 5. Fichiers cohérents (même PKI) ?
md5sum /etc/openvpn/ca.crt ~/openvpn-ca/pki/ca.crt
md5sum /etc/openvpn/serveur.crt ~/openvpn-ca/pki/issued/serveur.crt
md5sum /etc/openvpn/serveur.key ~/openvpn-ca/pki/private/serveur.key
```

---

## 11. Référence des commandes

```bash
# Installation initiale
sudo bash install.sh

# Ajouter un site
sudo nouveau-site.sh

# Créer un utilisateur (technicien ou temporaire)
sudo nouvel-utilisateur.sh

# Révoquer un accès
cd ~/openvpn-ca
./easyrsa revoke <nom>
./easyrsa gen-crl && sudo cp pki/crl.pem /etc/openvpn/

# Redémarrer OpenVPN
sudo systemctl restart openvpn@server

# Voir les connexions actives
sudo cat /var/log/openvpn-status.log

# Lister tous les certificats émis
ls ~/openvpn-ca/pki/issued/

# Vérifier expiration CRL
sudo openssl crl -in /etc/openvpn/crl.pem -noout -nextupdate
```

---

## Fichiers importants

| Fichier | Rôle |
|---------|------|
| `/etc/openvpn/server.conf` | Configuration principale du serveur |
| `/etc/openvpn/ccd/` | Profils par client (routes, IP fixes) |
| `/etc/openvpn/sites.csv` | Registre de tous les sites |
| `/etc/openvpn/scripts/client-connect.sh` | Injection dynamique des routes techniciens |
| `/etc/openvpn/crl.pem` | Liste de révocation des certificats |
| `~/openvpn-ca/pki/` | PKI complète (CA, certificats, clés) |
| `/var/log/openvpn.log` | Journal du serveur |
| `/var/log/openvpn-status.log` | Clients actuellement connectés |

---

