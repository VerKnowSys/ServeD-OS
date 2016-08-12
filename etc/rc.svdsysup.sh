#!/bin/sh
#
# ServeD system script to perform lockless filesystem binary updates

set +e

DEFAULT_PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/libexec:/Software/Zsh/exports:/Software/Git/exports"
DEFAULT_HOST_ADDRESS_FILE="/etc/host.default"
UPDATE_PENDING_INDICATOR="/.svdsysup"
SERVED_REPO="/var/ServeD-OS"
SOFIN_REPO="/var/sofin"
BACKUP_SVDINIT="/var/.svdinit"
UNBOUND_CONF_DIR="/var/unbound/conf.d"
UNBOUND_CONF="/var/unbound/unbound.conf"
UNBOUND_CONTROL_CONF="/var/unbound/control.conf"
DEFAULT_JAIL_PRISON_LOCATION="/Jails/Prison"
DEFAULT_JAIL_SHARED_LOCATION="/Jails/Shared"
JAIL_DOMAINS_COMMON_LOADER="include: ${DEFAULT_JAIL_PRISON_LOCATION}/Sentry/*/jail-domains/*.conf"
RSYNC_DEFAULT_OPTIONS="-l -p -E -A -X -o -g -t -r --delete"

SNAPSHOT_REGEXP="@[a-z0-9]{6,10}$" # origin or timestamp
SETUID_UNUSED_BINS="/bin/rsh /bin/rlogin"
SETUID_BINS="/sbin/init /sbin/svdinit /lib/libthr.so.3 /lib/libc.so.7 /lib/libcrypt.so.5 /libexec/ld-elf.so.1 /usr/lib/librt.so.1 /usr/bin/chfn /usr/bin/chsh /usr/bin/opiepasswd /usr/bin/crontab /usr/bin/passwd /usr/bin/chpass /usr/bin/opieinfo /usr/bin/su /usr/bin/login"

SVDSYSUP_PICKED_OS_VERSION="11.0" # the default
PATH="${DEFAULT_PATH}"

# Load Sofin environment:
if [ -d "${SOFIN_REPO}" ]; then
    cd ${SOFIN_REPO}
    . share/sofin/funs/self.fun
    load_requirements
fi
# ______________________________________________________________________________
# From now on, we want to log each svdsysup command to the log file..


debug () {
    /usr/bin/logger "${@}" || true
}


dnote () {
    note "${@}" && \
    debug "${@}" >> "${SVDSYSUP_LOG}" 2>> "${SVDSYSUP_LOG}"
}


wrun () {
    _args="${@}"
    debug "wrun: ${@}"
    run "${_args} && ${SYNC_BIN}"
}


# Some important values:
DEFAULT_ZPOOL="${DEFAULT_ZPOOL:-zroot}"
SVDSYSUP_TIMESTAMP="${SVDSYSUP_TIMESTAMP:-$(${DATE_BIN} +%s 2>/dev/null)}"
SVDSYSUP_LOG="/var/log/svdsysup-${SVDSYSUP_TIMESTAMP:-initial}.log"
SVDSYSUP_DEFAULT_INTERFACE_ADDRESS="$(${CAT_BIN} "${DEFAULT_HOST_ADDRESS_FILE}" 2>/dev/null)"

# these must be mounted to +w SVDSYSUP_LOG:
${ZFS_BIN} mount -v -a && \
    note "ZFS datasets mounted"

${ZFS_BIN} set readonly=off ${DEFAULT_ZPOOL} && \
${ZFS_BIN} set readonly=off ${DEFAULT_ZPOOL}/ROOT/default && \
${ZFS_BIN} set readonly=off ${DEFAULT_ZPOOL}/var && \
${ZFS_BIN} set readonly=off ${DEFAULT_ZPOOL}/var/log && \
${ZFS_BIN} set readonly=off ${DEFAULT_ZPOOL}/usr && \
${SYNC_BIN} && \
    dnote "Core datasets were successfully set writable and mounted"

wrun "${ZFS_BIN} snapshot ${DEFAULT_ZPOOL}/ROOT/default@${SVDSYSUP_TIMESTAMP}" && \
wrun "${ZFS_BIN} snapshot ${DEFAULT_ZPOOL}/usr@${SVDSYSUP_TIMESTAMP}" && \
dnote "Done pre-update snapshots with timestamp: ${SVDSYSUP_TIMESTAMP}"

# Set snochg flags.
for f in ${SETUID_BINS}; do
    ${CHFLAGS_BIN} noschg "${f}"
done
for f in ${SETUID_UNUSED_BINS}; do
    if [ -e "${f}" ]; then
        ${CHFLAGS_BIN} noschg "${f}" &&
            ${RM_BIN} -f "${f}"
    fi
done

# Update system version from system property
served_version="$(${ZFS_BIN} get -H -o value com.svd:version ${DEFAULT_ZPOOL}/ROOT 2>/dev/null)"
served_os_version="$(${ZFS_BIN} get -H -o value com.svd:os_version ${DEFAULT_ZPOOL}/ROOT 2>/dev/null)"
if [ "${served_os_version}" != "-" ]; then
    SVDSYSUP_PICKED_OS_VERSION="${served_os_version}"
fi

${TEST_BIN} ! -f /etc/fstab && ${TOUCH_BIN} /etc/fstab
if [ -d "/root" ]; then
    cd /
    dnote "Synchronizing /root to dataset: ${DEFAULT_ZPOOL}${DEFAULT_HOME}/root"
    wrun "${SERVED_REPO}${RSYNC_BIN} -v ${RSYNC_DEFAULT_OPTIONS} /root/ ${DEFAULT_HOME} 2>/dev/null"
    wrun "${PW_BIN} user mod root -d ${DEFAULT_HOME}"
    wrun "${PW_BIN} user mod toor -d ${DEFAULT_HOME}"
    wrun "${RM_BIN} -rf /root"
    dnote "Home directory synchronized successfully"
fi
wrun "${ZFS_BIN} set readonly=off ${DEFAULT_ZPOOL}${DEFAULT_HOME}/root"
${RM_BIN} -f /etc/zshenv /etc/zshrc
${MKDIR_BIN} -p /etc/zsh
${SERVED_REPO}${RSYNC_BIN} ${RSYNC_DEFAULT_OPTIONS} ${SERVED_REPO}/shell/ /etc/zsh
${LN_BIN} -s /etc/zsh/zshenv /etc/zshenv
${LN_BIN} -s /etc/zsh/zshrc /etc/zshrc

for folder in bin lib libexec sbin usr; do
    wrun "${SERVED_REPO}${RSYNC_BIN} --exclude='home' --exclude='ports' ${RSYNC_DEFAULT_OPTIONS} ${DEFAULT_JAIL_SHARED_LOCATION}/${OS_TRIPPLE}/${folder}/ /${folder}" 2>> ${SVDSYSUP_LOG} && \
    dnote "Synchronized: ${DEFAULT_JAIL_SHARED_LOCATION}/${OS_TRIPPLE}/${folder}/ to: /${folder}"
done

#-------------------------------------------------------------------------------
# NOTE: always do custom software installation after rsync synchro!

cd ${SOFIN_REPO} && bin/install
${INSTALL_BIN} -v ${SERVED_REPO}/gvr /usr/bin
${INSTALL_BIN} -v ${SERVED_REPO}/usr/bin/rsync /usr/bin
${CP_BIN} ${BACKUP_SVDINIT} /var/svdinit
${INSTALL_BIN} -v /var/svdinit /sbin
${RM_BIN} -f /var/svdinit
dnote "Installed core software"

# motd setup
header_extension="v${served_version}+v${SVDSYSUP_PICKED_OS_VERSION} "
if [ -x "${GIT_BIN}" ]; then
    if [ -f "/var/${SVDSYSUP_PICKED_OS_VERSION}-src/Makefile" ]; then
        cd /var/${SVDSYSUP_PICKED_OS_VERSION}-src/
        head16_hbsd_sha="$(${GIT_BIN} rev-parse HEAD 2>/dev/null | ${CUT_BIN} -c -16 2>/dev/null)"
        debug "HBSD repository HEAD: ${head16_hbsd_sha}"
        header_extension="${header_extension}#${head16_hbsd_sha}…"
    else
        header_extension="\t\t ${header_extension} (binary)"
    fi
fi
# build motd:
${RM_BIN} -f /etc/motd
${CP_BIN} -v ${SERVED_REPO}/etc/motd.served /etc/motd
${PRINTF_BIN} "\t${header_extension}\n-----------------------------------------\n\n" >> /etc/motd
cd /

# Bring back schg flags
for f in ${SETUID_BINS}; do
    ${CHFLAGS_BIN} schg "${f}"
done

# wrun "${ZFS_BIN} snapshot ${DEFAULT_ZPOOL}/ROOT/default@${SVDSYSUP_TIMESTAMP}-pre-v${served_version}" && \
# wrun "${ZFS_BIN} snapshot ${DEFAULT_ZPOOL}/usr@${SVDSYSUP_TIMESTAMP}-pre-v${served_version}" && \
# wrun "${ZFS_BIN} snapshot ${DEFAULT_ZPOOL}/var@${SVDSYSUP_TIMESTAMP}-pre-v${served_version}" && \
# dnote "Done post-update snapshots with timestamp: ${SVDSYSUP_TIMESTAMP}"

# destroy_oldest_snapshot () {
#     dataset_name="${1}"
#     dataset_last="$(${ZFS_BIN} list -H -S creation -t snap -o name 2>/dev/null | ${EGREP_BIN} "${dataset_name}${SNAPSHOT_REGEXP}" 2>/dev/null | ${SED_BIN} 's/.*@//;s/ .*//' 2>/dev/null | ${TAIL_BIN} -n1 2>/dev/null)"
#     wrun "${ZFS_BIN} destroy ${dataset_name}@${dataset_last}" && \
#     dnote "Dataset destroyed: ${dataset_name}@${dataset_last}"
#     unset dataset_name dataset_last
# }

# for dataset in ${DEFAULT_ZPOOL}/ROOT/default ${DEFAULT_ZPOOL}/usr ${DEFAULT_ZPOOL}/var; do
#     value="$(${ZFS_BIN} list -H -S creation -t snap -o name 2>/dev/null | ${EGREP_BIN} "${dataset}${SNAPSHOT_REGEXP}" 2>/dev/null | ${WC_BIN} -l 2>/dev/null | ${SED_BIN} 's/ //g' 2>/dev/null)"
#     wiped="0"
#     if [ ${value} -gt 20 ]; then
#         for s in $(${SEQ_BIN} 1 5); do
#             destroy_oldest_snapshot "${dataset}" && \
#             wiped="${wiped} +1"
#         done
#     elif [ ${value} -gt 10 ]; then
#         for s in $(${SEQ_BIN} 1 3); do
#             destroy_oldest_snapshot "${dataset}" && \
#             wiped="${wiped} +1"
#         done
#     elif [ ${value} -gt 5 ]; then
#         for s in $(${SEQ_BIN} 1 2); do
#             destroy_oldest_snapshot "${dataset}" && \
#             wiped="${wiped} +1"
#         done
#     fi && \
#     wiped="$(echo "${wiped}" 2>/dev/null | ${BC_BIN} 2>/dev/null)"
#     value="$(${ZFS_BIN} list -H -S creation -t snap -o name 2>/dev/null | ${EGREP_BIN} "${dataset}${SNAPSHOT_REGEXP}" 2>/dev/null | ${WC_BIN} -l 2>/dev/null | ${SED_BIN} 's/ //g' 2>/dev/null)"
#     dnote "Done snapshot cleanup of: ${dataset} (${value} available, ${wiped} wiped out)"
#     unset value wiped
# done


generate_conf_for_unbound_resolver () {
    dnote "Generating base configuration for Unbound"
    /usr/sbin/local-unbound-setup -n

    if [ ! -f "${UNBOUND_CONF_DIR}/jailed.conf" ]; then
        dnote "Creating jailed.conf loader, with contents: '${JAIL_DOMAINS_COMMON_LOADER}'"
        ${PRINTF_BIN} "${JAIL_DOMAINS_COMMON_LOADER}\n" > "${UNBOUND_CONF_DIR}/jailed.conf"
    fi

    ${PRINTF_BIN} "# Generated by ServeD updater #
server:
    username: unbound
    directory: /var/unbound
    chroot: /var/unbound
    pidfile: /var/run/local_unbound.pid
    interface: 127.0.0.1
    interface: ${SVDSYSUP_DEFAULT_INTERFACE_ADDRESS}
    access-control: 10.0.0.0/8 allow
    access-control: 100.64.1.0/24 allow
    access-control: 2001:470:1f15:488::/64 allow
    outgoing-num-tcp: 1 # this limits TCP service, uses less buffers.
    incoming-num-tcp: 1
    outgoing-range: 60  # uses less memory, but less performance.
    msg-buffer-size: 8192   # dnote this limits service, 'no huge stuff'.
    msg-cache-size: 100k
    msg-cache-slabs: 1
    rrset-cache-size: 100k
    rrset-cache-slabs: 1
    infra-cache-numhosts: 200
    infra-cache-slabs: 1
    key-cache-size: 100k
    key-cache-slabs: 1
    neg-cache-size: 10k
    num-queries-per-thread: 30
    target-fetch-policy: \"2 1 0 0 0 0\"
    harden-large-queries: \"yes\"
    harden-short-bufsize: \"yes\"
    prefetch: yes
    num-threads: 1
    use-caps-for-id: yes
    harden-dnssec-stripped: yes
    harden-glue: yes
    hide-identity: yes
    hide-version: yes
    # This option requires DNSSEC setup:
    # auto-trust-anchor-file: /var/unbound/root.key

    # Load user Cells configurations
    include: /var/unbound/conf.d/*.conf

include: /var/unbound/forward.conf
include: /var/unbound/lan-zones.conf
include: /var/unbound/control.conf
" > ${UNBOUND_CONF}

    # XXX: TODO: not really secure, consider using SSL certs per server and local user domains
    ${PRINTF_BIN} "# Generated by ServeD updater #
remote-control:
    control-enable: yes
    control-interface: /var/run/local_unbound.ctl
    control-use-cert: no
" > ${UNBOUND_CONTROL_CONF}
    ${CHOWN_BIN} -vR unbound /var/unbound || true
}

# Generate Unbound configuration with a little help from local-unbound-setup:
generate_conf_for_unbound_resolver
${RM_BIN} -vf ${UPDATE_PENDING_INDICATOR}
update_shell_vars || true
# wrun "${SOFIN_BIN} vars > ${DEFAULT_HOME}/.profile"

echo "Finished"
exit 0