#!/bin/sh

# url of the git repository where I keep my patched version of Apple's mDNSResponder
MDNSGIT="https://github.com/gkaindl/Community-mdnsResponder.git"

# debian package name for the package created by checkinstall during the script
PKGNAME="apple-dnsextd"

DNSEXTD_CONF_SAMPLE='options {
	listen-on   	port 53 {};
	nameserver	address 127.0.0.1 port 5030;
	private 	port 5533;
	llq	   	port 5352;
};

zone "my.wide-area-bonjour-domain.com." {
	type public;
	allow-update { key "my-secret-key-name"; };
};

key "my-secret-key-name" {
	secret "my-base64-encoded-secret-key";
};'

DNSEXTD_CONF=""
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
		fail "apple dnsextd is already installed. remove the package \"${PKGNAME}\" first if you want to reinstall."
	fi
	
	is_installed=$(dpkg-query -W -f='${Status}' "bind9" 2>&1)
	if [ "${is_installed}" = "${is_installed#install ok installed*}" ]; then
		fail "bind9 is not installed. please install it before installing dnsextd."
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

fetch_dnsextd () {
	notif "fetching dnsextd from ${MDNSGIT}..."

	git clone "${MDNSGIT}" "${DDIR}"

	if [ "$?" -ne 0 ]; then
		fail "failed to fetch dnsextd source from " "${MDNSGIT}"
	fi
}

build_dnsextd () {
	cd "${DDIR}/mdns-patched/mDNSPosix"

	if [ "$?" -ne 0 ]; then
		fail "unexpected directory structure in git checkout – maybe the project changed significantly?"
	fi

	notif "building dnsextd..."

	make os=linux dnsextd
}

install_dnsextd () {
	cd "${DDIR}/mdns-patched/mDNSPosix"

	if [ "$?" -ne 0 ]; then
		fail "unexpected directory structure in git checkout – maybe the project changed significantly?"
	fi

	notif "installing dnsextd..."

	checkinstall -y -D --fstrans=no --pkgname="${PKGNAME}" cp "${DDIR}/mdns-patched/mDNSPosix/build/prod/dnsextd" /usr/sbin
}

update_bind_options () {
	notif "updating bind options..."
	
	TMP=$(mktemp)
	
	sed 's/^\(.*listen-on.*port[^0-9]*\)53\([^0-9]\)/\15030\2/' /etc/bind/named.conf.options > "${TMP}"
	
	if [ "$(grep 'port\s*5030' "${TMP}" | wc -l)" -eq 0 ]; then
		F=$(sed "s|^};||g" "${TMP}")
		printf '%s\n\n	%s\n	%s\n};\n' "${F}" "listen-on-v6 port 5030 { any; };" "listen-on port 5030 { any; };" > "${TMP}"
	fi
	
	cat "${TMP}" > /etc/bind/named.conf.options
	rm "${TMP}"
}

install_dnsextd_config () {
	notif "installing dnsextd configuration..."

	if [ -z "${DNSEXTD_CONF}" ]; then
		if [ -f /etc/dnsextd.conf ]; then
			notif "/etc/dnsextd.conf exists, so not touching it..."
		else
			HAS_DNSEXTDCONF_SAMPLE="yes"
			
			if [ -f /etc/dnsextd.conf.sample ]; then
				notif "/etc/dnsextd.conf.sample exists, so not touching it..."
			else
				printf '%s\n' "${DNSEXTD_CONF_SAMPLE}" > /etc/dnsextd.conf.sample
			fi
		fi
	else
		rm -f /etc/dnsextd.conf.sample
		
		if [ -f /etc/dnsextd.conf ]; then
			notif "/etc/dnsextd.conf exists, so not touching it..."
		else
			printf '%s\n' "${DNSEXTD_CONF}" > /etc/dnsextd.conf
		fi
	fi
}

install_dnsextd_initd_and_upstart () {
	notif "installing /etc/init.d/dnsextd..."
	
	if [ -f /etc/init.d/dnsextd ]; then
		notif "init script at /etc/init.d/dnsextd already exists, so not touching it..."
	else
		cat > /etc/init.d/dnsextd <<-"EOF"
			# PROVIDE: dnsextd
			# REQUIRE: NETWORKING
			
			### BEGIN INIT INFO
			# Provides:        dnsextd
			# Required-Start:  bind9 $network $time $syslog
			# Required-Stop:   bind9 $network $time $syslog
			# Default-Start:   2 3 4 5
			# Default-Stop:    0 1 6
			# Short-Description: Apple dnsextd daemon
			### END INIT INFO
			
			if [ -r /usr/sbin/dnsextd ]; then
			    DAEMON=/usr/sbin/dnsextd
			else
			    DAEMON=/usr/local/sbin/dnsextd
			fi
			
			test -r $DAEMON || exit 0
			
			# Some systems have start-stop-daemon, some don't. 
			if [ -r /sbin/start-stop-daemon ]; then
			    START="start-stop-daemon --start --quiet --exec"
			    # Suse Linux doesn't work with symbolic signal names, but we really don't need
			    # to specify "-s TERM" since SIGTERM (15) is the default stop signal anway
			    # STOP="start-stop-daemon --stop -s TERM --quiet --oknodo --exec"
			    STOP="start-stop-daemon --stop --quiet --oknodo --exec"
			else
			    killdnsextd() {
			        if [ -f /var/run/dnsextd.pid ]; then
			            kill -TERM `cat /var/run/dnsextd.pid`
			        else
				        killall dnsextd > /dev/null 2>&1
				     fi
			    }
			    START=
			    STOP=killdnsextd
			fi
			
			case "$1" in
			    start)
			        echo -n "Starting Apple Darwin dnsextd daemon:"
			        echo -n " dnsextd"
			        $START $DAEMON
			        echo "."
			    ;;
			    stop)
			        echo -n "Stopping Apple Darwin dnsextd daemon:"
			        echo -n " dnsextd" ; $STOP $DAEMON
			        echo "."
			    ;;
			    reload|restart|force-reload)
			        echo -n "Restarting Apple Darwin dnsextd daemon::"
			        $STOP $DAEMON
			        sleep 1
			        $START $DAEMON
			        echo -n " dnsextd"
			    ;;
			    *)
			        echo "Usage: /etc/init.d/dnsextd {start|stop|reload|restart}"
			        exit 1
			    ;;
			esac
			
			exit 0
		EOF
		
		chmod a+x /etc/init.d/dnsextd
		update-rc.d -f dnsextd defaults > /dev/null 2>&1
	fi
	
	if [ -d /etc/init ]; then
		notif "system uses upstart, installing dnsextd upstart job..."
		
		if [ -f /etc/init/dnsextd.conf ]; then
			notif "upstart job /etc/init/dnsextd.conf exists, so not touching it..."
		else
			cat > /etc/init/dnsextd.conf <<-EOF
				description "dnsextd"
				
				respawn
				console none
				
				start on started bind9
				stop on stopped bind9
				
				pre-start exec /etc/init.d/dnsextd start
				post-stop exec /etc/init.d/dnsextd stop
			EOF
		fi
		
		if [ -f /etc/init/bind9.conf ]; then
			update-rc.d -f dnsextd remove > /dev/null 2>&1
		else
			notif "upstart job for bind9 doesn't exist, but we depend on it, so not removing dnsextd from init.d boot scripts..."
		fi
	fi
}

checks
install_debian_packages "git" "gcc" "make" "flex" "bison" "checkinstall"
fetch_dnsextd
build_dnsextd
install_dnsextd
update_bind_options
install_dnsextd_config
install_dnsextd_initd_and_upstart
clean_up

if [ "yes" = "${HAS_DNSEXTDCONF_SAMPLE}" ]; then
	echo
	echo "There is a configuration sample file at /etc/dnsextd.conf.sample"
	echo "Please customize this if necessary, remove the .sample postfix"
	echo "from the file name and restart the dnsextd daemon."
fi

echo
notif "apple dnsextd is now installed and ready."

