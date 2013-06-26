#!/bin/sh

# example mysql table for bind.
#
# the first line in each variable is the desired name of the zone table, and each
# subsequent line contains the DNS name, the TTL, the record type and record data
# separated by a comma.
BIND_TABLE="somedomain_com
   somedomain.com, 3600, SOA, somedomain.com. http://www.somedomain.com. 200906201 28800 7200 86400 28800
   somedomain.com, 3600, NS, ns.somedomain.com.
   someserver.somedomain.com, 3600, A, 192.168.1.1
   www.somedomain.com, 3600, CNAME, someserver.somedomain.com."

ROOT_PASSWORD=""
BIND_USER=""
BIND_PASSWORD=""
BIND_CONF_FILE="/etc/bind/named.conf.local"

CONFFILE="$(dirname `readlink -f ${0}`)-private/config-$(basename "${0}")"

if [ -f "${CONFFILE}" ]; then
   . "${CONFFILE}"
fi

if [ ! -z ${1} ]; then
   ROOT_PASSWORD="${1}"
fi

if [ ! -z ${2} ]; then
   BIND_USER="${2}"
fi

if [ ! -z ${3} ]; then
   BIND_PASSWORD="${3}"
fi

notif () {
   echo "\033[1;34m${1}\033[0m${2}"
}

fail () {
   echo "\033[1;31m${1}\033[0m${2}"
   exit 0
}

usage () {
   echo "\033[1;34musage:\033[0m $(basename $0) [mysql root password] [bind user name] [bind user password]"
   exit 0
}

run_mysql_cmd () {
   mysql_result=$(mysql -NB -u root -p${ROOT_PASSWORD} -e "${1}" 2>&1)
      
   if [ $? -gt 0 ]; then
      fail "mysql query \"${1}\" failed: " "${mysql_result}"
   fi
}

checks () {
   if ! [ $(id -u) = 0 ]; then
      fail "you need to be root to run this (or use sudo)."
   fi
   
   has_mysql=$(which mysql 2>/dev/null)
   if [ -z "${has_mysql}" ] ; then
      fail "mysql is not installed."
   fi
   
   mysqld_pid=$(pgrep -n mysqld)
   if [ -z "${mysqld_pid}" ]; then
      fail "mysqld is not running. please start mysqld first."
   fi
   
   has_bind=$(which named 2>/dev/null)
   if [ -z "${has_bind}" ] ; then
      fail "bind is not installed."
   fi
   
   if [ -z "${ROOT_PASSWORD}" ]; then
      usage
   fi
   if [ -z "${BIND_USER}" ]; then
      usage
   fi
   if [ -z "${BIND_PASSWORD}" ]; then
      usage
   fi
}

create_bind_user () {
   run_mysql_cmd "select user from mysql.user where user='${BIND_USER}'"
   
   if [ ! -z "${mysql_result}" ]; then
      notif "mysql user \"${BIND_USER}\" already exists."
   else
      notif "mysql user \"${BIND_USER}\" does not exist, creating it..."
      
      run_mysql_cmd "create user '${BIND_USER}'@'localhost' identified by '${BIND_PASSWORD}'"
   fi
}

create_bind_database () {
   DB_NAME="${1}"
   
   run_mysql_cmd "select schema_name from information_schema.schemata where schema_name='${DB_NAME}'"
   
   if [ ! -z "${mysql_result}" ]; then
      notif "mysql database \"${DB_NAME}\" already exists."
   else
      notif "mysql database \"${DB_NAME}\" does not exist, creating it..."
      
      run_mysql_cmd "create database ${DB_NAME}"
   fi
}

set_mysql_user_privileges_for_database () {
   DB_NAME="${1}"
   
   run_mysql_cmd "show grants for '${BIND_USER}'@'localhost'"
   
   privs=$(echo "${mysql_result}" | grep -i "ALL PRIVILEGES ON \`${DB_NAME}\`" | wc -l)
   if [ "${privs}" -gt 0 ]; then
      notif "mysql user \"${BIND_USER}\" already has all privileges on database \"${DB_NAME}\"."
   else
      notif "granting mysql user \"${BIND_USER}\" all privileges on database \"${DB_NAME}\"..."
      
      run_mysql_cmd "grant all on ${DB_NAME}.* to '${BIND_USER}'@'localhost'"
   fi
}

import_bind_zone_table () {
   DB="bind_$(printf '%s\n' "${BIND_TABLE}" | head -n 1)"
   VALUES=$(printf '%s\n' "${BIND_TABLE}" | tail -n +2)
   
   NAME="dns_records"
   
   create_bind_database "${DB}"
   set_mysql_user_privileges_for_database "${DB}"
   
   DB_EXISTS_CMD="select count(*) from information_schema.tables where table_schema='${DB}' and table_name='${NAME}'"
   
   run_mysql_cmd "${DB_EXISTS_CMD}"
   
   if [ "${mysql_result}" -gt 0 ]; then
      notif "table \"${NAME}\" in \"${DB}\" already exists. not touching it..."
   else
      notif "creating and initializing table \"${NAME}\" in \"${DB}\"..."
      
      run_mysql_cmd "use ${DB};
            CREATE TABLE \`${NAME}\` (
            \`id\` int(11) NOT NULL auto_increment,
            \`zone\` varchar(256) default NULL,
            \`host\` varchar(256) default NULL,
            \`type\` varchar(8) default NULL,
            \`data\` varchar(512) default NULL,
            \`ttl\` int(11) NOT NULL default '3600',
            \`mx_priority\` int(11) default NULL,
            \`refresh\` int(11),
            \`retry\` int(11),
            \`expire\` int(11),
            \`minimum\` int(11),
            \`serial\` bigint(20),
            \`resp_person\` varchar(64),
            \`primary_ns\` varchar(64),
            \`data_count\` int(11) NOT NULL default '0',
            PRIMARY KEY  (\`id\`),
            KEY \`host\` (\`host\`),
            KEY \`zone\` (\`zone\`),
            KEY \`type\` (\`type\`)
         ) ENGINE=MyISAM DEFAULT CHARSET=latin1"
      
      run_mysql_cmd "${DB_EXISTS_CMD}"
      
      if [ "${mysql_result}" -eq 0 ]; then
         fail "failed to create table \"${NAME}\" in \"${DB}\"."
      fi
      
      j=0
      printf '%s\n' "${VALUES}" | { while read LINE; do
         OIFS="$IFS"
         IFS=","
         
         SQL_INSERT="("
         
         i=0
         for FIELD in $LINE; do
            FIELD=$(echo "${FIELD}" | sed -e 's/^[[:space:]]*//g' -e 's/[[:space:]]*$//g')
            
            if [ "${FIELD}" != "null" ]; then
               FIELD="'${FIELD}'"
            fi
                        
            SQL_INSERT="${SQL_INSERT}${FIELD},"
                                    
            i=$((i+1))
         done
         
         if [ "${i}" -lt 4 ]; then
            fail "invalid bind database entry: \"${LINE}\"..."
         fi
         
         SQL_INSERT="${SQL_INSERT%?})"
         
         k=0
         FVAL="("
         for FNAM in zone host type data ttl mx_priority serial refresh retry expire minimum primary_ns resp_person; do
            FVAL="${FVAL}${FNAM},"
            k=$((k+1))
            
            if [ "${k}" -ge "${i}" ]; then
               break
            fi
         done
         
         FVAL="${FVAL%?})"
         
         IFS="$OIFS"
         
         run_mysql_cmd "use ${DB}; insert into \`${NAME}\` $FVAL VALUES $SQL_INSERT"
                  
         j=$((j+1))
      done
      }            
   fi
}

install_bind_zone_table () {   
   NAME="bind_$(printf '%s\n' "${BIND_TABLE}" | head -n 1)"
      
   ZONENAME=$(echo "${NAME}" | sed -nE 's/_/\./gp')

   if [ "$(grep "dlz \"${NAME}\"" "${BIND_CONF_FILE}" | wc -l)" -eq 1 ]; then
      notif "${NAME} database already referenced as dlz in ${BIND_CONF_FILE}, nothing to do..."
      return
   fi
   
   notif "adding dlz \"${NAME}\" to ${BIND_CONF_FILE}..."
   
   DLZ_DECLARATION="dlz \"${NAME}\" {
      database \"mysql
         {host=localhost dbname=${NAME} user=${BIND_USER} pass="${BIND_PASSWORD}"}
         {select zone from dns_records where zone = '\$zone\$'}
         {select ttl, type, mx_priority, case when lower(type)='txt' then concat('\\\"', data, '\\\"') else data end from dns_records where zone = '\$zone\$' and host = '\$record\$' and not (type = 'SOA' or type = 'NS')}
         {select ttl, type, mx_priority, data, resp_person, serial, refresh, retry, expire, minimum from dns_records where zone = '\$zone\$' and (type = 'SOA' or type='NS')}
         {select ttl, type, host, mx_priority, data, resp_person, serial, refresh, retry, expire, minimum from dns_records where zone = '\$zone\$' and not (type = 'SOA' or type = 'NS')}
         {select zone from xfr_table where zone = '\$zone\$' and client = '\$client\$'}
         {update data_count set count = count + 1 where zone ='\$zone\$'}\";
   };"
      
   printf '\n%s\n' "${DLZ_DECLARATION}" >> "${BIND_CONF_FILE}"
}

restart_bind () {
   notif "restarting bind..."
   
   /etc/init.d/bind9 restart
}

checks
create_bind_user
import_bind_zone_table
install_bind_zone_table
restart_bind

notif "bind setup for mysql database \"$(printf '%s' "${BIND_TABLE}" | head -n 1)\", table \"dns_records\"."
