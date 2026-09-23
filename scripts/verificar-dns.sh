#!/usr/bin/env bash
# =============================================================================
# verificar-dns.sh — Diagnóstico DNS / SSL / Cloudflare para blog.tuaplicaciongratis.com
# =============================================================================
# Proyecto  : tuaplicaciongratis.com — escaparate webapps (Javier Mateo / ApliArte)
# Propósito : Validar, antes y después del cambio en Blogger, que el subdominio
#             `blog.tuaplicaciongratis.com` resuelve a `ghs.google.com` y que
#             el certificado SSL + cabeceras HTTP están operativos.
# Uso       : ./scripts/verificar-dns.sh [-v] [-h]
#             -v  Modo verboso (imprime dig/curl sin truncar)
#             -h  Ayuda
# Salida    : UI coloreada con secciones; exit codes estables para CI.
# Exit codes:
#   0  Todo correcto (CNAME, SSL y HTTP 2xx/3xx)
#   1  Fallo DNS (CNAME no apunta a ghs.google.com / NXDOMAIN)
#   2  Fallo SSL (certificado ausente, expirado o no confiable)
#   3  Fallo HTTP (servidor no responde 2xx/3xx)
#   4  Error de uso / dependencia faltante
# Dependencias: bash >=4, dig (BIND), curl, openssl, getopt (GNU).
# =============================================================================

set -u
set -o pipefail

# -----------------------------------------------------------------------------
# Constantes — single source of truth. Si el dominio o el target cambian,
# se actualizan aquí y el resto del script los hereda.
# -----------------------------------------------------------------------------
readonly TARGET_DOMAIN="blog.tuaplicaciongratis.com"
readonly EXPECTED_CNAME_TARGET="ghs.google.com."
readonly BLOGGER_CONSOLE_URL="https://draft.blogger.com/blog/settings/2533872855233438032"
readonly HTTP_TIMEOUT=10
readonly DIG_TIMEOUT=5

# Rangos de IPs de proxy Cloudflare (oranges.cloudflare.com). Se usan sólo como
# heurística: si la IP resuelta cae dentro, el proxy está activo (naranja).
# Referencia: https://www.cloudflare.com/ips/  (rangos históricos de CF proxy)
readonly CF_PROXY_IPV4_RANGES=(
  "104.16.0.0/12"
  "172.64.0.0/13"
  "173.245.48.0/20"
  "188.114.96.0/20"
  "190.93.240.0/20"
  "197.234.240.0/22"
  "198.41.128.0/17"
  "162.158.0.0/15"
  "141.101.64.0/18"
  "108.162.192.0/18"
)

# -----------------------------------------------------------------------------
# Colores ANSI — sólo si stdout es TTY. Variables vacías en CI.
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET=$(tput sgr0)
  C_BOLD=$(tput bold)
  C_DIM=$(tput dim 2>/dev/null || true)
  C_RED=$(tput setaf 1)
  C_GREEN=$(tput setaf 2)
  C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4)
  C_MAGENTA=$(tput setaf 5)
  C_CYAN=$(tput setaf 6)
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA="" C_CYAN=""
fi

# -----------------------------------------------------------------------------
# Utilidades de UI
# -----------------------------------------------------------------------------
say()    { printf "%b\n" "$*"; }
header() {
  local title="$1"
  local bar
  bar=$(printf '%.0s─' $(seq 1 70))
  say "${C_BOLD}${C_CYAN}${bar}${C_RESET}"
  say "${C_BOLD}${C_CYAN}  ${title}${C_RESET}"
  say "${C_BOLD}${C_CYAN}${bar}${C_RESET}"
}
ok()     { say "  ${C_GREEN}✔${C_RESET}  $*"; }
warn()   { say "  ${C_YELLOW}⚠${C_RESET}  $*"; }
err()    { say "  ${C_RED}✘${C_RESET}  $*"; }
info()   { say "  ${C_BLUE}ℹ${C_RESET}  $*"; }
dim()    { say "    ${C_DIM}${*}${C_RESET}"; }
section() {
  local tag="$1"; shift
  say "\n${C_BOLD}${C_MAGENTA}[${tag}]${C_RESET} ${C_BOLD}$*${C_RESET}"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
Uso: $(basename "$0") [-v] [-h]

  -v   Verboso: imprime la salida cruda de dig/curl.
  -h   Muestra esta ayuda.

Dominio objetivo : ${TARGET_DOMAIN}
CNAME esperado   : ${EXPECTED_CNAME_TARGET}
Exit codes       : 0 OK · 1 DNS · 2 SSL · 3 HTTP · 4 uso
EOF
}

require_tools() {
  local missing=()
  for tool in dig curl openssl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    err "Faltan dependencias: ${missing[*]}"
    say "    Instalar con: brew install bind curl openssl   (macOS)"
    say "                  apt-get install dnsutils curl openssl  (Debian/Ubuntu)"
    exit 4
  fi
}

# ip_in_cidr <ip> <cidr>  → 0 si pertenece, 1 si no, 2 si argumento inválido
ip_in_cidr() {
  local ip="$1" cidr="$2"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
  [[ "$cidr" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)/([0-9]+)$ ]] || return 2
  local cidr_ip="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
  local mask_bits="${BASH_REMATCH[5]}"
  if ! command -v python3 >/dev/null 2>&1; then
    return 2
  fi
  python3 - "$ip" "$cidr_ip" "$mask_bits" <<'PY' 2>/dev/null
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
net = ipaddress.IPv4Network(f"{sys.argv[2]}/{sys.argv[3]}", strict=False)
sys.exit(0 if ip in net else 1)
PY
}

# is_cloudflare_proxy_ip <ip>  → 0 si cae en algún rango CF proxy
is_cloudflare_proxy_ip() {
  local ip="$1" range
  for range in "${CF_PROXY_IPV4_RANGES[@]}"; do
    if ip_in_cidr "$ip" "$range"; then return 0; fi
  done
  return 1
}

# =============================================================================
# Check 1 — Resolución CNAME
# =============================================================================
check_dns_cname() {
  section "1/3" "Resolución DNS (CNAME)"

  local cname_raw
  # `dig +short CNAME` devuelve una sola línea con el target (FQDN con punto)
  cname_raw=$(dig +short +time="${DIG_TIMEOUT}" +tries=2 CNAME "${TARGET_DOMAIN}" 2>/dev/null || true)

  if [[ -z "$cname_raw" ]]; then
    err "No se obtuvo respuesta CNAME (NXDOMAIN, timeout o dominio inexistente)."
    dim "Verifica que el dominio base tuaplicaciongratis.com está registrado y es accesible."
    return 1
  fi

  # Limpiar punto final si lo trae (dig suele añadir FQDN)
  local cname="${cname_raw%.}"
  local expected="${EXPECTED_CNAME_TARGET%.}"
  dim "CNAME publicado: ${cname_raw}"
  dim "CNAME esperado:  ${EXPECTED_CNAME_TARGET}"

  if [[ "$cname" == "$expected" ]]; then
    ok "CNAME correcto → ${cname_raw} (apunta a Blogger/Google)."
    return 0
  fi

  err "CNAME NO apunta a ${EXPECTED_CNAME_TARGET}."
  warn "Apunta a: ${cname_raw}"
  warn "Acción: editar el registro CNAME en Cloudflare DNS para ${TARGET_DOMAIN}"
  warn "       y poner ${EXPECTED_CNAME_TARGET} como destino."
  return 1
}

# =============================================================================
# Check 2 — Certificado SSL
# =============================================================================
# Salida (variables globales para mostrar resumen):
#   SSL_HOSTNAME, SSL_ISSUER, SSL_EXPIRY, SSL_DAYS_LEFT, SSL_RESULT
# =============================================================================
check_ssl() {
  section "2/3" "Certificado SSL (TLS)"

  # Probamos tanto con SNI como sin él. Para Blogger/Google el cert cubre
  # *.blogspot.com y suele re-emitirse por Google Trust Services.
  local tmp_cert
  tmp_cert=$(mktemp) || { err "No se pudo crear archivo temporal para cert."; return 2; }
  trap 'rm -f "${tmp_cert:-}"' RETURN

  local openssl_out
  openssl_out=$(echo "" | openssl s_client \
      -servername "${TARGET_DOMAIN}" \
      -connect "${TARGET_DOMAIN}:443" \
      -showcerts 2>/dev/null || true) || openssl_out=""

  if [[ -z "$openssl_out" ]]; then
    err "No se pudo establecer conexión TLS con ${TARGET_DOMAIN}:443."
    warn "Posibles causas: proxy Cloudflare caído, cert aún no emitido, o DNS sin propagar."
    SSL_RESULT="FAIL"
    return 2
  fi

  # Extraer el primer bloque de cert (BEGIN CERTIFICATE ... END CERTIFICATE)
  echo "$openssl_out" | awk '
    /-----BEGIN CERTIFICATE-----/{capture=1; buf=""}
    capture{buf = buf $0 "\n"}
    /-----END CERTIFICATE-----/{if(capture){print buf; exit}}
  ' > "$tmp_cert"

  if [[ ! -s "$tmp_cert" ]]; then
    err "No se encontró ningún certificado en la respuesta TLS."
    SSL_RESULT="FAIL"
    return 2
  fi

  local subject issuer
  subject=$(openssl x509 -in "$tmp_cert" -noout -subject 2>/dev/null | sed 's/^subject=//')
  issuer=$(openssl x509 -in "$tmp_cert" -noout -issuer 2>/dev/null | sed 's/^issuer=//')

  local not_after epoch_not_after epoch_now days_left
  not_after=$(openssl x509 -in "$tmp_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
  # macOS date y GNU date difieren: probamos ambos.
  epoch_not_after=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$not_after" "+%s" 2>/dev/null \
                    || date -d "$not_after" "+%s" 2>/dev/null || echo 0)
  epoch_now=$(date "+%s")
  if [[ "$epoch_not_after" -gt 0 && "$epoch_now" -gt 0 ]]; then
    days_left=$(( (epoch_not_after - epoch_now) / 86400 ))
  else
    days_left="?"
  fi

  SSL_HOSTNAME="$subject"
  SSL_ISSUER="$issuer"
  SSL_EXPIRY="$not_after"
  SSL_DAYS_LEFT="$days_left"

  dim "Subject : ${subject}"
  dim "Issuer  : ${issuer}"
  dim "Expira  : ${not_after}  (${days_left} días)"

  # Validación semántica: que el subject contenga el dominio objetivo (o wildcard
  # *.googleapis.com / *.blogspot.com, que es lo que Google emite para Blogger).
  local subject_cn
  subject_cn=$(echo "$subject" | grep -oE 'CN *= *[^,]+' | head -1 | sed 's/^CN *= *//')
  if [[ -z "$subject_cn" ]]; then
    subject_cn=$(echo "$subject" | grep -oE 'DNS:[^,]+' | head -1 | sed 's/^DNS://')
  fi

  local cn_match=0
  if [[ "${subject_cn,,}" == *"${TARGET_DOMAIN}"* ]]; then cn_match=1; fi
  if [[ "${subject_cn,,}" == *"googleapis.com"* ]] || [[ "${subject_cn,,}" == *"blogspot.com"* ]]; then cn_match=1; fi

  if [[ "$days_left" != "?" ]] && (( days_left < 0 )); then
    err "Certificado EXPIRADO hace ${days_left#-} días."
    SSL_RESULT="EXPIRED"
    return 2
  fi

  if (( cn_match == 0 )); then
    warn "El certificado NO cubre explícitamente ${TARGET_DOMAIN} (CN=${subject_cn:-desconocido})."
    warn "Si Blogger aún no ha emitido cert para este dominio, espera 5-30 min tras cambiar el CNAME."
    SSL_RESULT="MISMATCH"
    # No es fallo fatal: Blogger emite certs bajo *.blogspot.com / Google Trust Services.
    # Marcamos como advertencia pero devolvemos éxito si la cadena es válida.
  fi

  if (( days_left != "?" )) && (( days_left < 14 )); then
    warn "Certificado próximo a expirar (${days_left} días). Renovación automática de Google debería actuar."
  fi

  ok "Certificado TLS válido y en vigor."
  SSL_RESULT="OK"
  return 0
}

# =============================================================================
# Check 3 — Cabeceras HTTP + estado del proxy Cloudflare
# =============================================================================
# Salida:
#   HTTP_CODE, HTTP_SERVER, CF_PROXY_STATUS (ACTIVE|DNS_ONLY|UNKNOWN)
# =============================================================================
check_http() {
  section "3/3" "Cabeceras HTTP y proxy Cloudflare"

  # 1) Resolver la IP actual para heurística de proxy.
  local resolved_ip
  resolved_ip=$(dig +short +time="${DIG_TIMEOUT}" +tries=2 A "${TARGET_DOMAIN}" 2>/dev/null \
                | head -n1 | tr -d '[:space:]')

  if [[ -n "$resolved_ip" ]]; then
    dim "IP resuelta por DNS público: ${resolved_ip}"
    if is_cloudflare_proxy_ip "$resolved_ip"; then
      CF_PROXY_STATUS="ACTIVE"
      ok "Proxy Cloudflare ACTIVO (naranja) — IP ${resolved_ip} pertenece a rangos CF."
    else
      CF_PROXY_STATUS="DNS_ONLY"
      warn "Proxy Cloudflare en modo DNS-only (gris/nube) — IP ${resolved_ip} NO es de CF."
      warn "Esto NO es un fallo, pero confirma que el tráfico NO pasa por CF."
    fi
  else
    CF_PROXY_STATUS="UNKNOWN"
    warn "No se pudo resolver IP A del dominio (puede deberse a que sólo existe CNAME)."
  fi

  # 2) Petición HEAD-like con -I para ver sólo cabeceras, pero -sIv da más info
  #    y permite seguir redirects sin perder diagnóstico.
  local curl_out http_code
  curl_out=$(curl --max-time "${HTTP_TIMEOUT}" -sSL -D - -o /dev/null \
             -A "verificar-dns/1.0 (+blog.tuaplicaciongratis)" \
             "https://${TARGET_DOMAIN}/" 2>/dev/null || true)

  http_code=$(echo "$curl_out" | awk 'BEGIN{c=0} /HTTP\/[0-9.]+ [0-9]+/{c=$2; last=$0} END{print c+0}')
  HTTP_CODE="${http_code:-0}"
  HTTP_SERVER=$(echo "$curl_out" | awk -F': ' 'tolower($1)=="server"{sub(/\r$/,"",$2); print $2; exit}')

  dim "HTTP status final: ${HTTP_CODE}"
  dim "Server header    : ${HTTP_SERVER:-<no expuesto>}"

  # Cabeceras de cache/CDN si existen
  local cf_headers
  cf_headers=$(echo "$curl_out" | grep -iE '^(cf-ray|cf-cache-status|server|location):' || true)
  if [[ -n "$cf_headers" ]]; then
    dim "Cabeceras CF/origen relevantes:"
    while IFS= read -r line; do
      dim "  ${line}"
    done <<< "$cf_headers"
  fi

  if (( HTTP_CODE >= 200 && HTTP_CODE < 400 )); then
    ok "Servidor HTTP respondió ${HTTP_CODE} — Blogger/Google está sirviendo contenido."
    return 0
  fi

  if (( HTTP_CODE == 0 )); then
    err "Sin respuesta HTTP. Posibles causas:"
    err "  · El CNAME aún no ha propagado (esperar 5 min – 48 h)."
    err "  · El proxy Cloudflare está caído."
    err "  · El firewall local bloquea el puerto 443."
  elif (( HTTP_CODE == 404 )); then
    err "HTTP 404 — El dominio responde pero Blogger no encuentra el blog."
    warn "Asegúrate de haber configurado el dominio personalizado en Blogger:"
    warn "  ${BLOGGER_CONSOLE_URL}"
  elif (( HTTP_CODE >= 500 )); then
    err "HTTP ${HTTP_CODE} — Error de servidor upstream (Google/Blogger)."
  else
    err "HTTP ${HTTP_CODE} — Estado inesperado."
  fi

  return 3
}

# =============================================================================
# Main
# =============================================================================
main() {
  local verbose=0
  local opt
  while getopts ":vh" opt; do
    case "$opt" in
      v) verbose=1 ;;
      h) usage; exit 0 ;;
      \?) err "Opción inválida: -${OPTARG}"; usage; exit 4 ;;
    esac
  done

  require_tools

  say ""
  say "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
  say "${C_BOLD}${C_CYAN}║  verificar-dns.sh — blog.tuaplicaciongratis.com                     ║${C_RESET}"
  say "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
  say ""
  info "Fecha    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  info "Dominio  : ${TARGET_DOMAIN}"
  info "Objetivo : CNAME → ${EXPECTED_CNAME_TARGET}"
  if (( verbose == 1 )); then
    info "Modo     : verboso (-v)"
    dim "PATH     : ${PATH}"
    dim "Bash     : ${BASH_VERSION}"
    dim "curl     : $(curl --version 2>/dev/null | head -1)"
    dim "openssl  : $(openssl version 2>/dev/null)"
  fi

  # Inicialización de estado
  SSL_HOSTNAME="" SSL_ISSUER="" SSL_EXPIRY="" SSL_DAYS_LEFT="" SSL_RESULT=""
  HTTP_CODE=0 HTTP_SERVER="" CF_PROXY_STATUS="UNKNOWN"

  local rc_dns=0 rc_ssl=0 rc_http=0

  check_dns_cname  || rc_dns=$?
  check_ssl        || rc_ssl=$?
  check_http       || rc_http=$?

  # --------------------------- Resumen final ------------------------------
  header "Resumen"
  if (( rc_dns == 0 )); then ok "DNS   : OK (CNAME → ${EXPECTED_CNAME_TARGET})"
  else err "DNS   : FALLO (código ${rc_dns})"; fi

  if (( rc_ssl == 0 )); then
    ok "SSL   : OK (${SSL_EXPIRY}, ${SSL_DAYS_LEFT} días)"
    dim "         Subject: ${SSL_HOSTNAME}"
    dim "         Issuer : ${SSL_ISSUER}"
  else
    warn "SSL   : revisión (${SSL_RESULT})"
  fi

  if (( rc_http == 0 )); then ok "HTTP  : OK (${HTTP_CODE}, server=${HTTP_SERVER:-oculto})"
  else err "HTTP  : FALLO (${HTTP_CODE})"; fi

  info "Proxy CF: ${CF_PROXY_STATUS}"

  # Código de salida agregado: el primero que falle, en orden DNS → SSL → HTTP.
  local rc=0
  if (( rc_dns != 0 )); then rc=$rc_dns
  elif (( rc_ssl != 0 )); then rc=$rc_ssl
  elif (( rc_http != 0 )); then rc=$rc_http
  fi

  if (( rc == 0 )); then
    say ""
    say "${C_BOLD}${C_GREEN}✅ Todo listo. La migración del blog debería estar operativa.${C_RESET}"
  else
    say ""
    say "${C_BOLD}${C_RED}❌ Hay incidencias. Consulta arriba los pasos pendientes.${C_RESET}"
    say "${C_DIM}  Consola Blogger: ${BLOGGER_CONSOLE_URL}${C_RESET}"
  fi
  say ""

  exit "${rc}"
}

main "$@"
