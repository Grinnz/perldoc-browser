#!/bin/sh

# @author Bodo (Hugo) Barwich
# @version 2020-11-08
# @package Docker Deployment
# @subpackage entrypoint.sh
#



set -e

SERVER=`cat /etc/hostname`

MDNM=`basename $0`

echo "Container '${SERVER}.${COMPONENT}': '$MDNM' go ..."

echo "Container '${SERVER}.${COMPONENT}' - Network:"

echo `cat -A /etc/hosts`


if [ "$1" = "perldoc-browser.pl" ]; then
  echo "Command: '$@'"

  echo -n "Mojolicious Version: "

  mojolicious=`perl -MMojolicious -e 'print Mojolicious::VERSION . "\n"; ' 2>/dev/null`

  if [ -n "$mojolicious" ]; then
    echo "$mojolicious"
  else
    echo "NONE"
  fi

  echo -n "Search Backend: "

  backend=`cat perldoc-browser.conf | grep -i search_backend | cut -d"'" -f2`

  if [ -z "$backend" ]; then
    echo "not recognized!"
    echo "Falling back to SQLite Backend ..."
    backend="sqlite"
  else
    echo "$backend"
  fi  #if [ -z "$backend" ]; then

  if [ -z "$mojolicious" ]; then
    #Run cpanm Installation
    echo "Installing Dependencies with cpanm ..."

    date +"%s" > log/cpanm_install_$(date +"%F").log
    cpanm -vn --installdeps --with-feature=$backend . 2>&1 >> log/cpanm_install_$(date +"%F").log
    cpanmrs=$?
    date +"%s" >> log/cpanm_install_$(date +"%F").log

    echo "Installation finished with [$cpanmrs]"
  else
    echo "$mojolicious"
  fi  #if [ -z "$mojolicious" ]; then


  echo "Service '$1': Launching ..."
fi  #if [ "$1" = "perldoc-browser.pl" ]; then


exec ./$@
