#!/bin/sh


# the contents of this variable will be installed to /etc/mdnsd.conf. This is only
# necessary if you want to use wide-area bonjour, in which case the contents of this
# variable should look like this
# 
# hostname <your widea-area-bonjour hostname for this host>
# zone <your wide-area-bonjour zone name>
# secret-64 <your base64 encoded secret for updates>
# secret-name <the key name>
MDNSD_CONF=""

# in order to use TSIG auth, the clock needs to be set reasonably. if the host doesn't
# have a realtime clock with a battery, we need to access a time server. we use openntpd
# for that. since there's no safe way to check for a realtime clock with a battery, we'll
# simply assume that openntpd is needed if we are on an ARM platform. if you want to force
# the use or omission of openntpd, edit this variable below.
NEEDS_NTPD=$(dpkg --print-architecture 2>&1 | grep -i "^arm" | wc -l)

# url of the git repository where I keep my patched version of Apple's mDNSResponder
MDNSGIT="https://github.com/gkaindl/Community-mdnsResponder.git"

# debian package name for the package created by checkinstall during the script
PKGNAME="apple-mdns"

CONFFILE="$(dirname `readlink -f ${0}`)-private/config-$(basename "${0}")"

if [ -f "${CONFFILE}" ]; then
   . "${CONFFILE}"
fi

DDIR=$(mktemp -d)

clean_up () {
   rm -rf "${DDIR}"
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
   
   is_installed=$(dpkg-query -W -f='${Status}' "${PKGNAME}" 2>&1)
   if [ "${is_installed}" != "${is_installed#install ok installed*}" ]; then
      fail "apple mdnsresponder is already installed. remove the package \"${PKGNAME}\" first if you want to reinstall."
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

fetch_mdnsresponder () {
   notif "fetching mdnsresponder from ${MDNSGIT}..."
   
   git clone "${MDNSGIT}" "${DDIR}"
   
   if [ "$?" -ne 0 ]; then
      fail "failed to fetch mdnsresponder source from " "${MDNSGIT}"
   fi
}

build_mdnsresponder () {
   cd "${DDIR}/mdns-patched/mDNSPosix"
   
   if [ "$?" -ne 0 ]; then
      fail "unexpected directory structure in git checkout – maybe the project changed significantly?"
   fi
   
   notif "building mdnsresponder..."
   
   make os=linux
}

install_mdnsresponder () {
   cd "${DDIR}/mdns-patched/mDNSPosix"
   
   if [ "$?" -ne 0 ]; then
      fail "unexpected directory structure in git checkout – maybe the project changed significantly?"
   fi
   
   notif "installing mdnsresponder..."
   
   checkinstall -y -D --exclude=/etc/nsswitch.conf --pkgname="${PKGNAME}" make os=linux install
}

setup_ntpd () {
   if [ "${NEEDS_NTPD}" -eq 0 ]; then
      notif "system probably has realtime clock with battery, won't setup openntpd..."
   else
      notif "system probably lacks realtime clock with battery, configuring openntpd..."
      
      install_debian_packages "openntpd"
      
      if [ "$(grep DAEMON_OPTS /etc/default/openntpd| grep -- '-s' | wc -l)" -eq 0 ]; then
         notif "adding -s flag to daemon options in /etc/default/openntpd..."
         
         TMP=$(mktemp)
         sed 's/\(DAEMON_OPTS\s*=\s*"[^"]*\)/\1 -s/' /etc/default/openntpd > "${TMP}"
         cat "${TMP}" > /etc/default/openntpd
         rm "${TMP}"
      else
         notif "openntpd daemon options already include the -s flag..."
      fi
      
      if [ -f /etc/init.d/mdns ]; then
         if [ "$(grep openntpd /etc/init.d/mdns | wc -l)" -eq 0 ]; then
            notif "adding openntpd as a start dependency to /etc/init.d/mdns..."
            
            TMP=$(mktemp)
            sed 's/\(Required-Start:\s*\)/\1openntpd /' /etc/init.d/mdns > "${TMP}"
            sed 's/\(Required-Stop:\s*\)/\1openntpd /' "${TMP}" > /etc/init.d/mdns
            rm "${TMP}"
            
            update-rc.d -f mdns defaults > /dev/null 2>&1
         else
            notif "openntpd is already a start dependency in /etc/init.d/mdns..."
         fi
      else
         notif "no /etc/init.d/mdns found, so not adding openntpd as a dependency..."
      fi
   fi
}

setup_upstart () {
   if [ -d /etc/init ]; then
      if [ ! -f /etc/init/mdns.conf ]; then
         notif "adding upstart profile for mdns..."
         
         DEPS="local-filesystems and net-device-up IFACE!=lo"
         if [ "${NEEDS_NTPD}" -ne 0 ]; then
            DEPS="openntpd and ${DEPS}"
         fi
         
         cat > /etc/init/mdns.conf <<-EOF
				description "Apple mDNS"
				
				respawn
				console none
				
				start on (${DEPS})
				stop on runlevel [!12345]
				
				pre-start exec /etc/init.d/mdns start
				post-stop exec /etc/init.d/mdns stop 
			EOF
      else
         notif "upstart profile for mdns already present, not touching it..."
      fi
      
      update-rc.d -f mdns remove > /dev/null 2>&1
      
      if [ "${NEEDS_NTPD}" -ne 0 ]; then
         if [ ! -f /etc/init/openntpd.conf ]; then
            notif "adding upstart profile for openntpd..."
      
            cat > /etc/init/openntpd.conf <<-EOF
					description "openntpd"
					
					respawn
					console none
					
					emits openntpd
					
					start on (local-filesystems and net-device-up IFACE!=lo)
					stop on runlevel [!12345]
					
					pre-start exec /etc/init.d/openntpd start 
					post-start exec initctl emit openntpd
					post-stop exec /etc/init.d/openntpd stop 
				EOF
         else
            notif "upstart profile for openntpd already present, not touching it..."
         fi
         
         update-rc.d -f openntpd remove > /dev/null 2>&1
      fi
   else
      notif "system doesn't use upstart, so not adding any profiles..."
   fi
}

install_config_files () {
   if [ ! -f /etc/mdnsd-services.conf ] && [ ! -f /etc/mdnsd-services.conf.sample ]; then
      notif "adding example configuration at /etc/mdnsd-services.conf..."
      
      LABEL="ssh service on $(hostname -s)"
      
      cat > /etc/mdnsd-services.conf.sample <<-EOF
			${LABEL}
			_ssh._tcp.
			22
			
			${LABEL}, wide-area bonjour
			_ssh._tcp. my.wide-area-bonjour-domain.com.
			22
		EOF
		
		HAS_SERVCONF_SAMPLE="yes"
   else
      notif "/etc/mdnsd-services.conf (or sample) already present, so not adding it..."
      
      if [ -f /etc/mdnsd-services.conf.sample ]; then
         HAS_SERVCONF_SAMPLE="yes"
      fi
   fi
   
   if [ ! -z "${MDNSD_CONF}" ]; then
      if [ ! -f /etc/mdnsd.conf ]; then
         notif "creating /etc/mdnsd.conf..."
         
         printf '%s\n' "${MDNSD_CONF}" > /etc/mdnsd.conf
         
         if [ -f /etc/init.d/mdns ]; then
            /etc/init.d/mdns restart > /dev/null 2>&1
         fi
      else
         notif "configuration file /etc/mdnsd.conf already exists, not touching it..."
      fi
   else
      notif "no content for /etc/mdnsd.conf specified in the script, so not touching this..."
   fi
}

checks
install_debian_packages "git" "gcc" "make" "flex" "bison" "checkinstall"
fetch_mdnsresponder
build_mdnsresponder
install_mdnsresponder
setup_ntpd
setup_upstart
install_config_files
clean_up

if [ "yes" = "${HAS_SERVCONF_SAMPLE}" ]; then
   echo
   echo "There is a configuration sample file at /etc/mdnsd-services.conf.sample"
   echo "Please customize this for the services you want to advertise, remove the"
   echo ".sample postfix from the file name and restart the mdns daemon."
   echo
   echo "When editing this file, be extra careful not to have any spaces at the"
   echo "end of a line – this would confuse the mdns responder daemon and cause"
   echo "the offending service not to be advertised!"
fi

echo
notif "apple mdnsd is now installed and ready."
