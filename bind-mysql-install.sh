#!/bin/sh

BIND_PACKAGE="bind9"
APPARMOR_RULE="/etc/apparmor.d/local/usr.sbin.named"
BIND_ZONE_FILE="/etc/bind/named.conf.local"
BIND_OPTIONS_FILE="/etc/bind/named.conf.options"

EXTRA_OPTIONS=""
ZONE0=""
KEY0=""
ASSIGN0=""

DDIR=$(mktemp -d)

CONFFILE="$(dirname `readlink -f ${0}`)-private/config-$(basename "${0}")"

if [ -f "${CONFFILE}" ]; then
   . "${CONFFILE}"
fi

clean_up () {
   rm -rf "$DDIR"
}

notif () {
   echo "\033[1;34m${1}\033[0m${2}"
}

fail () {
   echo "\033[1;31m${1}\033[0m${2}"
   clean_up
   exit 0
}

checks () {
   if ! [ $(id -u) = 0 ]; then
      fail "you need to be root to run this (or use sudo)."
   fi
   
   is_installed=$(dpkg-query -W -f='${Status}' "${BIND_PACKAGE}" 2>&1)
   if [ "${is_installed}" != "${is_installed#install ok installed*}" ]; then
   	fail "bind9 is already installed. remove the package \"${BIND_PACKAGE}\" first if you want to reinstall."
   fi
}

install_debian_packages () {
   notif "checking packages..."

   for package in "$@"; do
      package_status=$(dpkg-query -W -f='${Status} ${Version}' "${package}" 2>&1)      

      if [ "${package_status}" = "${package_status#install ok installed*}" ]; then
         if [ "$(apt-cache search "^${package}\$" | wc -l)" -eq 0 ]; then
            fail "\tunknown package: " "${package}"
         fi

         notif "\tpackage \"${package}\" is not installed, installing..."

         export DEBIAN_FRONTEND=noninteractive
         apt-get -qqy install "${package}" 1>/dev/null 2>&1

         notif "\t\tinstalled ${package}: " "$(dpkg-query -W -f='${Version}' "${package}" 2>/dev/null)"
      else
         notif "\tpackage \"${package}\" is already installed: " "$(echo "${package_status}" | awk '{print $NF}')"
      fi
   done
}

retrieve_debian_source_packages () {
   notif "downloading debian source packages..."

   for package in "$@"; do {
      cd "${DDIR}"
      result=$(apt-get source "${package}" 2>&1)

      if [ "${result}" != "${success#*You must put some 'source' URIs in your sources.list}" ]; then
         DIST=$(lsb_release -is)
         RELEASE=$(lsb_release -cs)

         case "${DIST}" in
            *buntu)
               echo "deb-src http://archive.ubuntu.com/ubuntu/ ${RELEASE} main" >> /etc/apt/sources.list
               apt-get -qqy update 1>/dev/null 2>&1
               result=$(apt-get source "${package}" 2>&1)
            ;;

            *ebian)
               echo "deb-src http://ftp.br.debian.org/debian ${RELEASE} main" >> /etc/apt/sources.list
               apt-get -qqy update 1>/dev/null 2>&1
               result=$(apt-get source "${package}" 2>&1)
            ;;

            *)
               fail "you need to add deb-src lines to your apt sources.list."
            ;;
         esac
      fi

      if [ "${result}" != "${result#*nable to find a source package}" ]; then
         fail "\tunknown source package: " "${package}"
      else
         notif "\tdownloaded sources: " "$(ls "${DDIR}" | grep -i "${package}" | head -n 1)"
      fi
   } done
}

patch_build_rules () {
   notif "enabling dlz-mysql driver in ${BIND_PACKAGE} build rules..."
   
   SRCPATH="${DDIR}"/"$(ls "${DDIR}" | grep -i "${BIND_PACKAGE}" | head -n 1)"
   
   TMP=$(mktemp)
   sed 's/\(configure:\)/EXTRA_FEATURES+=--with-dlz-mysql=yes\n\n\1/' "${SRCPATH}/debian/rules" > "${TMP}"
   cat "${TMP}" > "${SRCPATH}/debian/rules"
   rm "${TMP}"
}

build_and_install_bind () {
   notif "fetching build dependencies for bind..."
   
   apt-get -qqy build-dep "${BIND_PACKAGE}"
   
   notif "building ${BIND_PACKAGE}..."
   
   SRCPATH="${DDIR}"/"$(ls "${DDIR}" | grep -i "${BIND_PACKAGE}" | head -n 1)"
   {  
      cd "${SRCPATH}"
      dpkg-buildpackage
   }
   
   notif "installing bind..."
   
   rm -f "${DDIR}"/lwresd_*.deb
   dpkg -i "${DDIR}"/*.deb
}

update_bind_settings () {
   if [ "$(grep OPTIONS /etc/default/bind9 | grep -- '-n 1' | wc -l)" -eq 0 ]; then
      notif "adding -n 1 flag to daemon options in /etc/default/bind9..."
      
      TMP=$(mktemp)
      sed 's/\(OPTIONS\s*=\s*"[^"]*\)/\1 -n 1/' /etc/default/bind9 > "${TMP}"
      cat "${TMP}" > /etc/default/bind9
      rm "${TMP}"
   else
      notif "bind9 daemon options already include the -n 1 flag..."
   fi
}

update_apparmor () {
   if [ -f "${APPARMOR_RULE}" ]; then
      if [ "$(grep '/usr/share/mysql/' "${APPARMOR_RULE}" | wc -l)" -ne 0 ]; then
         notif "apparmor rule for bind/mysql already present, nothing to do..."
      else
         notif "updating apparmor for bind/mysql..."
         
         echo "" >> "${APPARMOR_RULE}"
         echo '/usr/share/mysql/ r,' >> "${APPARMOR_RULE}"
         echo '/usr/share/mysql/** rwk,' >> "${APPARMOR_RULE}"
         
         /etc/init.d/apparmor restart
      fi
   fi
}

modify_start_order () {
	if [ -f /etc/init.d/bind9 ]; then
		if [ "$(grep mysql /etc/init.d/bind9 | wc -l)" -eq 0 ]; then
			notif "adding mysql as a start dependency to /etc/init.d/bind9..."
			
			TMP=$(mktemp)
			sed 's/\(Required-Start:\s*\)/\1mysql /' /etc/init.d/bind9 > "${TMP}"
			sed 's/\(Required-Stop:\s*\)/\1mysql /' "${TMP}" > /etc/init.d/bind9
			rm "${TMP}"
			
			update-rc.d -f bind9 defaults > /dev/null 2>&1
		else
			notif "mysql is already a start dependency in /etc/init.d/bind9..."
		fi
	fi
	
   if [ -d /etc/init ]; then
      if [ ! -f /etc/init/bind9.conf ]; then
         notif "system uses upstart, adding bind9.conf to start bind after mysql..."
         
         cat > /etc/init/bind9.conf <<-EOF
				description "bind9"
				
				respawn
				console none
				
				start on started mysql
				stop on stopped mysql
				
				pre-start script
				   /etc/init.d/bind9 start
				end script
				
				post-stop script
				   /etc/init.d/bind9 stop
				end script
			EOF
      else
	      notif "system uses upstart, but /etc/init/bind9.conf exists, so not touching it..."
      fi
      
      update-rc.d -f bind9 remove > /dev/null 2>&1
   fi
}

install_zone_file () {
   NAME="${1}"
   CONTENT="${2}"
   FILENAME="/etc/bind/db.${NAME}"
   TARGETNAME="/var/lib/bind/db.${NAME}"
   ZONENAME="${NAME}"
   
   if [ "$(echo "${ZONENAME}" | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | wc -l)" -ne 0 ]; then
      ZONENAME="${ZONENAME}.in-addr.arpa"
   fi
   
   if [ -f "${FILENAME}" ]; then
      notif "bind zone file \"${FILENAME}\" already exists, not touching it..."
   else
      notif "installing zone file \"${FILENAME}\"..."
      
      printf '%s\n\n' "${CONTENT}" > "${FILENAME}"
   fi
   
   if [ "$(grep -E "zone\\s+\"${ZONENAME}\"" "${BIND_ZONE_FILE}" | wc -l)" -ne 0 ]; then
      notif "zone \"${ZONENAME}\" already referenced in ${BIND_ZONE_FILE}, nothing to do..."
   else
      notif "adding zone \"${ZONENAME}\" to ${BIND_ZONE_FILE}..."
      
      echo >> "${BIND_ZONE_FILE}"
      echo "zone \"${ZONENAME}\" {" >> "${BIND_ZONE_FILE}"
      echo "	type master;" >> "${BIND_ZONE_FILE}"
      echo "	file \"${TARGETNAME}\";" >> "${BIND_ZONE_FILE}"
      echo "	journal \"${TARGETNAME}.jnl\";" >> "${BIND_ZONE_FILE}"
      echo "};" >> "${BIND_ZONE_FILE}"
   fi
   
   if [ "$(grep "cp -f ${FILENAME}" /etc/init.d/bind9 | wc -l)" -ne 0 ]; then
      notif "${FILENAME} already copied to ${TARGETNAME} in /etc/init.d/bind9, nothing to do..."
   else
      notif "setting ${FILENAME} to be copied to ${TARGETNAME} in /etc/init.d/bind9..."
      
      TMP=$(mktemp)
      sed "s|\([^a-z]start)\)|\1\n\tcp -f "${FILENAME}" "${TARGETNAME}" >\/dev\/null 2>\&1; chown bind:bind "${TARGETNAME}"; rm -f "${TARGETNAME}".jnl;|" /etc/init.d/bind9 > "${TMP}"
      cat "${TMP}" > /etc/init.d/bind9
      rm "${TMP}"
   fi
}

install_zone_files () {
   if [ -z "${ZONE0}" ]; then
      notif "there are no zone files defined in the environment. you should define at least " "ZONE0"
   fi

   i=0
   while [ true ]; do
      ZF=$(eval printf \'%s\\\n\' "\"\${ZONE${i}}\"")

      if [ -z "${ZF}" ]; then
         break;
      fi

      NAME=$(printf '%s\n' "${ZF}" | head -n 1)
      CONTENT=$(printf '%s\n' "${ZF}" | tail -n +2)

      install_zone_file "${NAME}" "${CONTENT}"

      i=$((i+1))
   done
}

install_update_key () {
   NAME="${1}"
   KEY="${2}"

   if [ "$(grep "\"${NAME}\" {" "${BIND_ZONE_FILE}" | wc -l)" -eq 0 ]; then
      notif "installing update key \"${NAME}\"..."

      echo >> "${BIND_ZONE_FILE}"
      echo "key \"${NAME}\" {" >> "${BIND_ZONE_FILE}"
      echo "	algorithm hmac-md5;" >> "${BIND_ZONE_FILE}"
      echo "	secret \"${KEY}\";" >> "${BIND_ZONE_FILE}"
      echo "};" >> "${BIND_ZONE_FILE}"
   else
      notif "update key \"${NAME}\" is already installed..."
   fi
}

install_update_keys () {
   if [ -z "${KEY0}" ]; then
      notif "no update keys to install, skipping..."
   fi

   i=0
   while [ true ]; do
      LINE=$(eval printf \'%s\\\n\' "\"\${KEY${i}}\"")

      if [ -z "${LINE}" ]; then
         break;
      fi

      NAME=$(echo "${LINE}" | awk '{print $1}')
      SECRET=$(echo "${LINE}" | awk '{print $2}')

      install_update_key "${NAME}" "${SECRET}"

      i=$((i+1))
   done
}

assign_update_key () {
   ZONE="${1}"
   KEYNAME="${2}"

   notif "assigning update key \"${KEYNAME}\" to zone \"${ZONE}\"..."

   CONFLINE="	allow-update { key \"${KEYNAME}\"; };"
   TMPNAM="$(mktemp)"
   cat "${BIND_ZONE_FILE}" | perl -e 'while (<STDIN>) {if ($f>0 && $h==0 && /^\s*};\s*$/) { print "$ARGV[0]\n};\n"; $f=0; } else { print; } $f=1 if (/"\Q$ARGV[1]" {/); $h=1 if (m/\Q$ARGV[0]/);}' "${CONFLINE}" "${ZONE}" > "${TMPNAM}" 
   cat "${TMPNAM}" > "${BIND_ZONE_FILE}"
   rm "${TMPNAM}"
}

assign_update_keys () {
   if [ -z "${ASSIGN0}" ]; then
      notif "no update keys to assign to zones, skipping..."
   fi

   i=0
   while [ true ]; do
      LINE=$(eval printf \'%s\\\n\' "\"\${ASSIGN${i}}\"")

      if [ -z "${LINE}" ]; then
         break;
      fi

      ZONE=$(echo "${LINE}" | awk '{print $1}')
      KEYNAME=$(echo "${LINE}" | awk '{print $2}')

      assign_update_key "${ZONE}" "${KEYNAME}"

      i=$((i+1))
   done
}

add_bind_options () {
   if [ -z "${EXTRA_OPTIONS}" ]; then
      notif "no extra bind options defined, skipping..."
      return
   fi

   if [ $(grep "// $(basename "${0}") options" "${BIND_OPTIONS_FILE}" | wc -l) -ne 0 ]; then
      notif "bind/mysql-specific options already present, nothing to do..."
   else
      notif "adding bind/mysql-specific options..."

      OPTS=$(printf '\n\n	// %s\n%s\n};\n' "$(basename "${0}") options" "${EXTRA_OPTIONS}")

      TMPNAM="$(mktemp)"
      F=$(sed "s|^};||g" "${BIND_OPTIONS_FILE}")

      printf '%s%s\n' "${F}" "${OPTS}" > "${TMPNAM}"

      cat "${TMPNAM}" > "${BIND_OPTIONS_FILE}"
      rm "${TMPNAM}"
   fi
}

checks
install_debian_packages "dpkg-dev" "libmysqlclient-dev"
retrieve_debian_source_packages "${BIND_PACKAGE}"
patch_build_rules
build_and_install_bind
update_bind_settings
update_apparmor
modify_start_order
install_zone_files
install_update_keys
assign_update_keys
add_bind_options
clean_up

echo
notif "bind9 with dlz-mysql driver installed and ready."
