#!/bin/bash
# ================== VPS BURGOS - Script abierto estilo ADM VPS ==================
# Funciona en Debian/Ubuntu. Sin dependencias externas ni keys.
# by Burgos & ChatGPT (abierto, editable y auditable)

[[ $EUID -ne 0 ]] && { echo "Ejecute como root."; exit 1; }

# ---------- Degradado azul -> morado ----------
GRADIENT=(33 69 75 81 99 129 135 141 177 183 219)
RESET="\e[0m"; _line_idx=0
eco_grad(){ local c=${GRADIENT[$((_line_idx % ${#GRADIENT[@]}))]}; echo -e "\e[38;5;${c}m$*${RESET}"; ((_line_idx++)); }
eco_grad_n(){ local c=${GRADIENT[$((_line_idx % ${#GRADIENT[@]}))]}; printf "\e[38;5;${c}m%s${RESET}" "$*"; ((_line_idx++)); }
reset_grad(){ _line_idx=0; }

# ---------- Utilidades ----------
detect_pkgmgr(){ command -v apt-get &>/dev/null && echo apt || echo unknown; }
PKGMGR=$(detect_pkgmgr)

ensure_pkg(){
  [[ "$PKGMGR" != "apt" ]] && return 0
  local need=()
  for p in "$@"; do dpkg -s "$p" &>/dev/null || need+=("$p"); done
  if ((${#need[@]})); then
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}" >/dev/null 2>&1
  fi
}

get_ip(){
  # varios métodos; el primero que responda
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$ip" ]] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7;exit}')
  [[ -z "$ip" ]] && ip=$(curl -sS --max-time 3 ifconfig.me)
  [[ -z "$ip" ]] && ip=$(wget -qO- --timeout=3 ifconfig.me)
  echo "${ip:-desconocido}"
}

get_ssh_ports(){
  local ports
  ports=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2}' /etc/ssh/sshd_config 2>/dev/null | tr '\n' ' ')
  [[ -z "$ports" ]] && ports="22"
  echo "$ports"
}
get_ssh_port(){ echo "$(get_ssh_ports | awk '{print $1}')" ; }

get_ssl_ports(){
  local p
  [[ -f /etc/stunnel/stunnel.conf ]] || { echo ""; return; }
  p=$(awk -F= '/^[[:space:]]*accept[[:space:]]*=/{gsub(/[ \t]/,"");print $2}' /etc/stunnel/stunnel.conf | awk -F: '{print $NF}' | tr '\n' ' ')
  echo "$p"
}
get_ssl_port(){ local x; x=$(get_ssl_ports); [[ -n "$x" ]] && echo "$x" | awk '{print $1}' || echo ""; }

solo_usuarios_ssh(){ awk -F: '$3>=1000 && $1!="nobody"{print $1}' /etc/passwd; }

open_firewall(){
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "$1"/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
  fi
}

# ---------- Instalación / Configuración ----------
instalar_stack(){
  reset_grad; clear
  eco_grad "=== Instalación básica (SSH + SSL/Stunnel) ==="
  if [[ "$PKGMGR" != "apt" ]]; then
    eco_grad "Este instalador soporta APT (Debian/Ubuntu)."
    read -rp $'\nPresione ENTER para volver...'
    return
  fi

  ensure_pkg curl wget openssl stunnel4 net-tools iproute2 xclip xsel
  systemctl enable ssh >/dev/null 2>&1
  systemctl restart ssh >/dev/null 2>&1

  # Configurar Stunnel4 si no existe
  if [[ ! -f /etc/stunnel/stunnel.conf ]]; then
    eco_grad "Configurando Stunnel4..."
    mkdir -p /etc/stunnel
    # Certificado autofirmado válido 1095 días
    openssl req -new -x509 -days 1095 -nodes -subj "/CN=$(get_ip)" \
      -out /etc/stunnel/stunnel.pem -keyout /etc/stunnel/stunnel.pem >/dev/null 2>&1
    chmod 600 /etc/stunnel/stunnel.pem
    cat > /etc/stunnel/stunnel.conf <<EOF
pid = /var/run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4
client = no
foreground = no
debug = 3
output = /var/log/stunnel4.log

[ssh-ssl]
accept = 443
connect = 127.0.0.1:$(get_ssh_port)
cert = /etc/stunnel/stunnel.pem
EOF
    sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || true
    open_firewall 443
  fi

  systemctl enable stunnel4 >/dev/null 2>&1
  systemctl restart stunnel4 >/dev/null 2>&1

  eco_grad "✅ Instalación/actualización completada."
  eco_grad "IP: $(get_ip) | SSH: $(get_ssh_ports) | SSL: $(get_ssl_ports || echo none)"
  read -rp $'\nPresione ENTER para continuar...'
}

# ---------- Gestión de usuarios ----------
crear_usuario(){
  reset_grad; clear
  eco_grad "=== Crear usuario SSH ==="
  eco_grad_n "Usuario: "; read -r user
  [[ -z "$user" ]] && { eco_grad "Cancelado."; return; }
  id "$user" &>/dev/null && { eco_grad "❌ Ya existe."; return; }
  eco_grad_n "Contraseña: "; read -r pass
  eco_grad_n "Días de duración: "; read -r dias
  [[ -z "$dias" || ! "$dias" =~ ^[0-9]+$ ]] && { eco_grad "❌ Días inválidos."; return; }

  expira=$(date -d "+$dias days" +"%Y-%m-%d")
  useradd -e "$expira" -M -s /bin/false "$user" || { eco_grad "❌ Error al crear."; return; }
  echo "$user:$pass" | chpasswd

  mkdir -p /root/usuarios_ssh
  ficha="/root/usuarios_ssh/$user.txt"
  cat <<EOF > "$ficha"
===== SSH BURGOS =====
Usuario: $user
Contraseña: $pass
Expira: $expira
IP: $(get_ip)
Puerto SSH: $(get_ssh_ports)
Puerto SSL: $(get_ssl_ports)
======================
EOF

  eco_grad ""
  eco_grad "===== SSH BURGOS ====="
  eco_grad "Usuario: $user"
  eco_grad "Contraseña: $pass"
  eco_grad "Expira: $expira"
  eco_grad "IP: $(get_ip)"
  eco_grad "Puerto SSH: $(get_ssh_ports)"
  eco_grad "Puerto SSL: $(get_ssl_ports)"
  eco_grad "======================"
  eco_grad "✅ Usuario creado. Ficha guardada en: $ficha"

  echo
  eco_grad_n "¿Desea copiar la información al portapapeles? (s/n): "
  read -r copy
  if [[ "$copy" =~ ^[sS]$ ]]; then
    if command -v xclip &>/dev/null; then
      xclip -selection clipboard < "$ficha"
      eco_grad "📋 Copiado al portapapeles con xclip."
    elif command -v xsel &>/dev/null; then
      xsel --clipboard --input < "$ficha"
      eco_grad "📋 Copiado al portapapeles con xsel."
    elif command -v pbcopy &>/dev/null; then
      pbcopy < "$ficha"
      eco_grad "📋 Copiado con pbcopy (Mac)."
    elif command -v termux-clipboard-set &>/dev/null; then
      termux-clipboard-set < "$ficha"
      eco_grad "📋 Copiado en Termux."
    else
      eco_grad "⚠️ No se encontró utilidad de portapapeles."
    fi
  fi
  read -rp $'\nPresione ENTER para continuar...'
}

editar_usuario(){
  reset_grad; clear
  eco_grad "=== Editar usuario SSH ==="
  mapfile -t usuarios < <(solo_usuarios_ssh)
  ((${#usuarios[@]}==0)) && { eco_grad "No hay usuarios."; read -rp $'\nENTER...'; return; }

  local i=1; for u in "${usuarios[@]}"; do eco_grad "$i) $u"; ((i++)); done
  eco_grad_n "Seleccione: "; read -r sel
  [[ -z "$sel" || "$sel" -le 0 || "$sel" -gt ${#usuarios[@]} ]] && return
  user="${usuarios[$((sel-1))]}"

  eco_grad_n "Nueva contraseña (ENTER para omitir): "; read -r pass
  [[ -n "$pass" ]] && echo "$user:$pass" | chpasswd
  eco_grad_n "Nuevos días (ENTER para omitir): "; read -r dias
  if [[ -n "$dias" && "$dias" =~ ^[0-9]+$ ]]; then
    expira=$(date -d "+$dias days" +"%Y-%m-%d")
    chage -E "$expira" "$user"
    eco_grad "Nueva expiración: $expira"
  fi
  eco_grad "✅ Usuario actualizado."
  read -rp $'\nENTER...'
}

listar_usuarios(){
  reset_grad; clear
  eco_grad "=== Listar usuarios SSH ==="
  local found=0
  while IFS=: read -r name _ uid _ _ _ _; do
    [[ $uid -ge 1000 && $name != "nobody" ]] || continue
    found=1
    exp=$(chage -l "$name" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')
    lock=$(passwd -S "$name" 2>/dev/null | awk '{print $2}')
    eco_grad "• $name  (expira: ${exp:-desconocido})  estado: ${lock}"
  done < /etc/passwd
  [[ $found -eq 0 ]] && eco_grad "No hay usuarios."
  read -rp $'\nENTER...'
}

bloquear_usuario(){
  reset_grad; clear
  eco_grad "=== Bloquear usuario SSH ==="
  eco_grad_n "Usuario: "; read -r user
  id "$user" &>/dev/null || { eco_grad "No existe."; read -rp $'\nENTER...'; return; }
  passwd -l "$user" &>/dev/null && eco_grad "🔒 Bloqueado."
  read -rp $'\nENTER...'
}

desbloquear_usuario(){
  reset_grad; clear
  eco_grad "=== Desbloquear usuario SSH ==="
  eco_grad_n "Usuario: "; read -r user
  id "$user" &>/dev/null || { eco_grad "No existe."; read -rp $'\nENTER...'; return; }
  passwd -u "$user" &>/dev/null && eco_grad "🔓 Desbloqueado."
  read -rp $'\nENTER...'
}

eliminar_usuario(){
  reset_grad; clear
  eco_grad "=== Eliminar usuario SSH ==="
  eco_grad_n "Usuario: "; read -r user
  id "$user" &>/dev/null || { eco_grad "No existe."; read -rp $'\nENTER...'; return; }
  userdel -r "$user" 2>/dev/null
  rm -f "/root/usuarios_ssh/$user.txt"
  eco_grad "🗑 Eliminado."
  read -rp $'\nENTER...'
}

# ---------- Puertos / Servicios ----------
monitorear_usuarios(){
  reset_grad; clear
  eco_grad "=== Usuarios conectados (who) ==="
  who || true
  echo
  eco_grad "=== Conexiones TCP establecidas por IP ==="
  ss -tn state established 2>/dev/null | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -nr
  read -rp $'\nENTER...'
}

reiniciar_servicios(){
  reset_grad; clear
  eco_grad "🔄 Reiniciando SSH y Stunnel..."
  systemctl restart ssh 2>/dev/null
  systemctl restart stunnel4 2>/dev/null
  eco_grad "✅ Servicios reiniciados."
  read -rp $'\nENTER...'
}

cambiar_puerto_ssh(){
  reset_grad; clear
  eco_grad "=== Cambiar puerto SSH principal ==="
  eco_grad "Puerto(s) actual(es): $(get_ssh_ports)"
  eco_grad_n "Nuevo puerto: "; read -r p
  [[ ! "$p" =~ ^[0-9]+$ ]] && { eco_grad "❌ Inválido."; read -rp $'\nENTER...'; return; }
  if grep -qi "^Port " /etc/ssh/sshd_config; then
    sed -i "0,/^[#[:space:]]*Port[[:space:]]\+[0-9]\+/{s//Port $p/}" /etc/ssh/sshd_config
  else
    echo "Port $p" >> /etc/ssh/sshd_config
  fi
  open_firewall "$p"
  systemctl restart ssh
  eco_grad "✅ Nuevo puerto SSH: $p"
  read -rp $'\nENTER...'
}

agregar_puerto_ssh(){
  reset_grad; clear
  eco_grad "=== Agregar puerto SSH adicional ==="
  eco_grad "Puertos actuales: $(get_ssh_ports)"
  eco_grad_n "Ingrese nuevo puerto SSH: "; read -r p
  [[ ! "$p" =~ ^[0-9]+$ ]] && { eco_grad "❌ Inválido."; read -rp $'\nENTER...'; return; }
  echo "Port $p" >> /etc/ssh/sshd_config
  open_firewall "$p"
  systemctl restart ssh
  eco_grad "✅ Puerto SSH $p agregado."
  read -rp $'\nENTER...'
}

agregar_puerto_ssl(){
  reset_grad; clear
  eco_grad "=== Agregar puerto SSL adicional (stunnel) ==="
  [[ ! -f /etc/stunnel/stunnel.conf ]] && { eco_grad "❌ No se encontró stunnel. Use 'Instalar/Configurar' primero."; read -rp $'\nENTER...'; return; }
  eco_grad "Puertos SSL actuales: $(get_ssl_ports)"
  eco_grad_n "Ingrese nuevo puerto SSL: "; read -r p
  [[ ! "$p" =~ ^[0-9]+$ ]] && { eco_grad "❌ Inválido."; read -rp $'\nENTER...'; return; }
  cat <<EOF >> /etc/stunnel/stunnel.conf

[ssh-$p]
client = no
accept = $p
connect = 127.0.0.1:$(get_ssh_port)
cert = /etc/stunnel/stunnel.pem
EOF
  open_firewall "$p"
  systemctl restart stunnel4
  eco_grad "✅ Puerto SSL $p agregado y habilitado."
  read -rp $'\nENTER...'
}

info_servidor(){
  reset_grad; clear
  eco_grad "=== Información del servidor ==="
  eco_grad "Hostname: $(hostname)"
  eco_grad "IP Pública: $(get_ip)"
  eco_grad "Puerto(s) SSH: $(get_ssh_ports)"
  eco_grad "Puerto(s) SSL: $(get_ssl_ports || echo none)"
  if command -v lsb_release >/dev/null 2>&1; then
    eco_grad "Sistema: $(lsb_release -d | cut -f2)"
  else
    . /etc/os-release 2>/dev/null
    eco_grad "Sistema: ${PRETTY_NAME:-Desconocido}"
  fi
  eco_grad "Kernel: $(uname -r)"
  eco_grad "Uptime: $(uptime -p)"
  eco_grad "RAM libre: $(free -m | awk '/Mem:/{print $4\" MB\"}')"
  read -rp $'\nENTER...'
}

# ---------- Menús ----------
menu_usuarios(){
  while :; do
    reset_grad; clear
    eco_grad "==== GESTIÓN DE USUARIOS 👤 ===="
    eco_grad "1) Crear usuario SSH"
    eco_grad "2) Editar usuario SSH"
    eco_grad "3) Listar usuarios SSH"
    eco_grad "4) Bloquear usuario SSH"
    eco_grad "5) Desbloquear usuario SSH"
    eco_grad "6) Eliminar usuario SSH"
    eco_grad "0) Volver"
    eco_grad ""
    eco_grad_n "Seleccione: "; read -r op
    case "$op" in
      1) crear_usuario ;;
      2) editar_usuario ;;
      3) listar_usuarios ;;
      4) bloquear_usuario ;;
      5) desbloquear_usuario ;;
      6) eliminar_usuario ;;
      0) return ;;
      *) eco_grad "Opción inválida"; sleep 1 ;;
    esac
  done
}

menu_herramientas(){
  while :; do
    reset_grad; clear
    eco_grad "===== HERRAMIENTAS ⚒️ ====="
    eco_grad "1) Instalar/Configurar SSH + SSL (stunnel)"
    eco_grad "2) Monitorear usuarios activos"
    eco_grad "3) Reiniciar servicios SSH/SSL"
    eco_grad "4) Cambiar puerto SSH principal"
    eco_grad "5) Agregar puerto SSH adicional"
    eco_grad "6) Agregar puerto SSL adicional"
    eco_grad "7) Información del servidor"
    eco_grad "0) Volver"
    eco_grad ""
    eco_grad_n "Seleccione: "; read -r op
    case "$op" in
      1) instalar_stack ;;
      2) monitorear_usuarios ;;
      3) reiniciar_servicios ;;
      4) cambiar_puerto_ssh ;;
      5) agregar_puerto_ssh ;;
      6) agregar_puerto_ssl ;;
      7) info_servidor ;;
      0) return ;;
      *) eco_grad "Opción inválida"; sleep 1 ;;
    esac
  done
}

menu_principal(){
  while :; do
    reset_grad; clear
    eco_grad "==============================="
    eco_grad " 🔐 Bienvenido a VPS Burgos "
    eco_grad " --- Tu conexión segura --- "
    eco_grad "==============================="
    eco_grad ""
    eco_grad "📱 WhatsApp: 9851169633"
    eco_grad "📬 Telegram: @Escanor_Sama18"
    eco_grad ""
    eco_grad "⚠️  Acceso autorizado únicamente."
    eco_grad "🔴 Todo acceso será monitoreado y registrado."
    eco_grad ""
    eco_grad "===== MENU VPS BURGOS ====="
    eco_grad "1) Gestión de usuarios 👤"
    eco_grad "2) Herramientas ⚒️"
    eco_grad "0) Salir"
    eco_grad ""
    eco_grad_n "Seleccione: "; read -r op
    case "$op" in
      1) menu_usuarios ;;
      2) menu_herramientas ;;
      0) clear; exit 0 ;;
      *) eco_grad "Opción inválida"; sleep 1 ;;
    esac
  done
}

# ---------- Inicio ----------
menu_principal
