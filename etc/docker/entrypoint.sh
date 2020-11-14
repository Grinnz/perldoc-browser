#!/bin/sh



set -e

SERVER=`cat /etc/hostname`

MDNM=`basename $0`

echo "Container '${SERVER}.${COMPONENT}': '$MDNM' go ..."

echo "Container '${SERVER}.${COMPONENT}' - Network:"

echo `cat -A /etc/hosts`


if [ "$1" = "perldoc-browser.pl" ]; then
  echo "Command: '$@'"

  echo "Configuring Local Installation ..."
  perl -Mlocal::lib ;
  eval $(perl -I ~/perl5/lib/perl5/ -Mlocal::lib) ;

  echo -n "Mojolicious Version: "

  perl -MMojolicious -e 'print $Mojolicious::VERSION; ' 2>/dev/null 1>log/perl_mojolicious.log ||\
    iresult=$?

  if [ -z "$iresult" ]; then
    iresult=0
  fi

  mojolicious=`cat log/perl_mojolicious.log`

  if [ -n "$mojolicious" ]; then
    echo "$mojolicious [Code: '$iresult']"
  else
    echo "NONE [Code: '$iresult']"
  fi

  echo -n "Search Backend: "

  cat perldoc-browser.conf 2>/dev/null | grep -i search_backend | cut -d"=" -f2 | cut -d"'" -f2 >log/web_backend.log ||\
    iresult=$?

  backend=`cat log/web_backend.log`

  if [ -z "$backend" ]; then
    echo "not recognized [Code: '$iresult']!"
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
  fi  #if [ -z "$mojolicious" ]; then


  echo "Service '$1': Launching ..."

  #Executing the Mojolicious Application
  exec ./$@

fi  #if [ "$1" = "perldoc-browser.pl" ]; then


#Launching any other Command
exec $@
