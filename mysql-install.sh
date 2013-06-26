#!/bin/sh

MYPASSWORD=""

if [ ! -z ${1} ]; then
   MYPASSWORD="${1}"
fi

notif () {
   echo "\033[1;34m${1}\033[0m${2}"
}

fail () {
   echo "\033[1;31m${1}\033[0m${2}"
   exit 0
}

checks () {
   if ! [ $(id -u) = 0 ]; then
      fail "you need to be root to run this (or use sudo)."
   fi
   
   if [ -z "${MYPASSWORD}" ]; then
      fail "please specify a mysql root user password as first argument."
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

set_mysql_root_password () {
   success=$(mysqladmin -u root password "${MYPASSWORD}" 2> /dev/null)
   
   if [ "${success}" = "${success#*failed}" ]; then
      notif "mysql root user password could not be set (maybe it is already set?)."
   else
      notif "mysql root user password set successfully."
   fi
}

secure_mysql () {
   # does what mysql_secure_installation normally does, but non-interactively
   sql_cmds="DELETE FROM mysql.user WHERE User='';
      DELETE FROM mysql.user WHERE User='root' AND Host!='localhost';
      DROP DATABASE test;    
      DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
      FLUSH PRIVILEGES;"
      
   success=$(mysql -u root -p${MYPASSWORD} -e "${sql_cmds}" 2>&1)
   
   test=$(echo "${success}" | sed 's/^ERROR//')
   if [ "${success}" != "${test}" ]; then
      test=$(echo "${success}" | sed 's/^ERROR 1008 (HY000)//')
      if [ "${success}" != "${test}" ]; then
         notif "mysql installation has already been secured."
      else
         fail "failed to secure mysql installation: " "${success}"
      fi
   else
      notif "secured mysql installation."
   fi
}

checks
install_debian_packages "mysql-server" "mysql-client"
set_mysql_root_password
secure_mysql

notif "mysql is now installed and ready."
