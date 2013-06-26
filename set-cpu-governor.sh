#!/bin/sh

GOVERNOR="performance"
CPUFREQ_DEF="/etc/default/cpufrequtils"

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
   
   has_cpufreq=$(which cpufreq-set 2>/dev/null)
   if [ ! "${has_cpufreq}" ]; then
      fail "you need to install the cpufreq utilities (apt-get install cpufrequtils)."
   fi
}

check_governor () {
   avail_govs=$(cpufreq-info | grep "available cpufreq governors: ")
   avail_govs=${avail_govs#*available cpufreq governors: }
   
   OIFS=$IFS
   IFS=", "
   for gov in $avail_govs; do
      if [ "$gov" = "${GOVERNOR}" ]; then
         gov_ok="yes"
      fi
   done
   IFS=$OIFS
   
   if [ "yes" = "${gov_ok}" ]; then
      notif "cpu freq governor \"${GOVERNOR}\" is available."
   else
      fail "invalid cpu freq governor: \"${GOVERNOR}\". possible governors are: " "${avail_govs}"
   fi
}

set_default_governor () {
   if [ -f "${CPUFREQ_DEF}" ]; then
      has_gov=$(grep "GOVERNOR=\"${GOVERNOR}\"" "${CPUFREQ_DEF}")
      has_enb=$(grep "ENABLE=\"true\"" "${CPUFREQ_DEF}")
      
      if [ ! -z "${has_enb}" ] && [ ! -z "${has_gov}" ]; then
         notif "governor \"${GOVERNOR}\" already configured in ${CPUFREQ_DEF}"
      else
         needs_def="yes"
      fi
   fi
   
   if [ "yes" = "${needs_def}" ]; then
      cat > "${CPUFREQ_DEF}" <<-EOF
			ENABLE="true"
			GOVERNOR="${GOVERNOR}"
			MAX_SPEED="0"
			MIN_SPEED="0"
		EOF
      
      notif "configured \"${GOVERNOR}\" in " "${CPUFREQ_DEF}"
   fi
}

disable_initd_ondemand () {
   has_ondemand=$(ls "/etc/rc2.d/" | grep "ondemand")
   
   if [ ! -z "${has_ondemand}" ]; then
      update-rc.d -f ondemand remove
      
      notif "removed \"ondemand\" from rcX.d"
   else
      notif "\"ondemand\" has already been removed from rcX.d"
   fi
}

set_current_governor () {
   has_governor=$(cpufreq-info | grep "\"${GOVERNOR}\" may decide which")
   
   if [ ! -z "${has_governor}" ]; then
      notif "governor \"${GOVERNOR}\" already is the active cpu freq governor."
   else
      cpufreq-set -g "${GOVERNOR}"
      notif "made \"${GOVERNOR}\" the active cpu freq governor."
   fi
}

if [ ! -z ${1} ]; then
   GOVERNOR="${1}"
fi

checks
check_governor
set_default_governor
disable_initd_ondemand
set_current_governor
