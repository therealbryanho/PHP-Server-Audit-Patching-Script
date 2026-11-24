#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
shopt -s nullglob

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }
active() { systemctl is-active --quiet "$1"; }

mode=${1:-audit}
case "$mode" in audit|plan|apply) ;; *) die "Usage: $0 [audit|plan|apply]" ;; esac
(( EUID == 0 )) || die "Run with sudo."
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) die "Only Ubuntu and Debian are supported." ;; esac
[[ -d /run/systemd/system ]] || die "This script requires systemd."

php_packages() {
    dpkg-query -W -f='${db:Status-Status}\t${binary:Package}\t${Version}\n' |
        awk -F '\t' '$1 == "installed" &&
            $2 ~ /^(php-common(:[^:]+)?$|(php|libapache2-mod-php)[0-9]+\.[0-9]+([-:]|$))/ {
            print $2 "\t" $3
        }'
}

audit() {
    local units unit pid version
    local -a pools=(/etc/php/*/fpm/pool.d/*.conf)

    section "Installed APT PHP packages and full package revisions"
    php_packages

    section "Default CLI PHP (not the website runtime)"
    if command -v php >/dev/null; then
        php -r 'echo PHP_VERSION, " (", PHP_SAPI, ")\n";'
    else
        echo "No default php CLI command found."
    fi

    section "Active PHP-FPM units and process executables"
    units=$(systemctl list-units --type=service --state=active \
        --no-legend --plain 'php*-fpm.service')
    while read -r unit _; do
        [[ "$unit" =~ ^php([0-9]+\.[0-9]+)-fpm\.service$ ]] || continue
        version=${BASH_REMATCH[1]}
        pid=$(systemctl show -p MainPID --value "$unit")
        printf '%s  PID=%s  running=%s\n' "$unit" "$pid" \
            "$(readlink "/proc/$pid/exe" || echo unavailable)"
        if [[ -x "/usr/sbin/php-fpm$version" ]]; then
            "/usr/sbin/php-fpm$version" -v | sed -n '1p'
        fi
    done <<< "$units"

    section "Configured PHP-FPM pool listeners"
    if ((${#pools[@]})); then
        grep -HnE '^[[:space:]]*listen[[:space:]]*=' "${pools[@]}" ||
            [[ $? == 1 ]]
    fi

    if active nginx.service; then
        section "Nginx hostnames and FastCGI routing (review in context)"
        nginx -T | awk '
            /^# configuration file/ ||
            /^[[:space:]]*(server_name|listen|root|upstream|fastcgi_pass)[[:space:]]/
        '
    fi

    if active apache2.service; then
        section "Apache virtual hosts and PHP handlers (review in context)"
        apache2ctl -S
        apache2ctl -M | awk '/php[[:alnum:]_]*_module|proxy_fcgi_module/'
        grep -rEn '^[[:space:]]*(SetHandler|ProxyPassMatch|ProxyPass|LoadModule[[:space:]]+php)' \
            /etc/apache2/sites-enabled /etc/apache2/conf-enabled \
            /etc/apache2/mods-enabled || [[ $? == 1 ]]
    fi
}

audit
[[ "$mode" != audit ]] || exit 0

installed=$(php_packages)
[[ -n "$installed" ]] || die "No matching APT-managed PHP packages found."
mapfile -t packages < <(cut -f1 <<< "$installed")

section "Refresh APT indexes"
apt-get -o APT::Update::Error-Mode=any update

section "APT package candidates and repository origins"
apt-cache policy "${packages[@]}"

section "Simulated upgrade"
plan=$(apt-get -s --only-upgrade --no-remove install "${packages[@]}")
printf '%s\n' "$plan"
if grep -Eq '^Inst [^[:space:]]+ \(' <<< "$plan"; then
    die "The plan adds a package. Review the dependencies manually."
fi
if ! grep -q '^Inst ' <<< "$plan"; then
    echo "No package upgrades proposed. No explicit restarts performed."
    exit 0
fi
[[ "$mode" == apply ]] || exit 0

read -r -p 'Type PATCH to apply the upgrade: ' approval
[[ "$approval" == PATCH ]] || die "Cancelled."

section "Record active services and check configuration"
units=$(systemctl list-units --type=service --state=active \
    --no-legend --plain 'php*-fpm.service')
fpm_units=()
while read -r unit _; do
    [[ "$unit" =~ ^php([0-9]+\.[0-9]+)-fpm\.service$ ]] || continue
    version=${BASH_REMATCH[1]}
    "/usr/sbin/php-fpm$version" -t
    fpm_units+=("$unit")
done <<< "$units"

restart_apache=0
if active apache2.service; then
    apache2ctl configtest
    modules=$(apache2ctl -M)
    if grep -Eq '^[[:space:]]*php[[:alnum:]_]*_module[[:space:]]' <<< "$modules"; then
        restart_apache=1
    fi
fi
if active nginx.service; then nginx -t; fi

section "Install updates"
apt-get --only-upgrade --no-remove install "${packages[@]}"

section "Restart and verify PHP runtimes"
failed=0
for unit in "${fpm_units[@]}"; do
    version=${unit#php}
    version=${version%-fpm.service}
    if ! "/usr/sbin/php-fpm$version" -t ||
       ! systemctl restart "$unit" ||
       ! active "$unit"; then
        printf 'Check: journalctl -u %s -n 50 --no-pager\n' "$unit" >&2
        failed=1
    fi
done
if (( restart_apache )); then
    if ! apache2ctl configtest ||
       ! systemctl restart apache2.service ||
       ! active apache2.service; then
        echo 'Check: journalctl -u apache2.service -n 50 --no-pager' >&2
        failed=1
    fi
fi
(( failed == 0 )) || die "At least one runtime failed verification. Check it before returning traffic."

audit
echo "Package update complete. Verify each application over HTTP."