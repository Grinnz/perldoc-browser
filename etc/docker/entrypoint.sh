#!/bin/sh



set -e

SERVER=`cat /etc/hostname`

MDNM=`basename $0`

echo "Container '${SERVER}.${COMPONENT}': '$MDNM' go ..."

echo "Container '${SERVER}.${COMPONENT}' - Network:"

echo `cat -A /etc/hosts`


if [ "$1" = "perldoc-browser.pl" ]; then
  sfeatures=""
  sfeatoptions=""
  icpanm=0

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

    #Trigger cpanm Installation
    icpanm=1
  fi  #if [ -n "$mojolicious" ]; then

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

  if [ -n "$backend" ]; then
    sfeatures="${sfeatures}${backend}"
  fi

  case "$backend" in
    sqlite)
      #Checking Dependencies for SQLite Backend

      echo -n "Mojo::SQLite Version: "

      perl -MMojo::SQLite -e 'print $Mojo::SQLite::VERSION; ' 2>/dev/null 1>log/mojo_sqlite.log ||\
        iresult=$?

      if [ -z "$iresult" ]; then
        iresult=0
      fi

      iversion=`cat log/mojo_sqlite.log`

      if [ -n "$iversion" ]; then
        echo "$iversion [Code: '$iresult']"
      else
        echo "NONE [Code: '$iresult']"

        #Trigger cpanm Installation
        icpanm=1
      fi  #if [ -n "$iversion" ]; then
      ;;

    pg)
      #Checking Dependencies for PostgreSQL Backend

      echo -n "Mojo::Pg Version: "

      perl -MMojo::Pg -e 'print $Mojo::Pg::VERSION; ' 2>/dev/null 1>log/mojo_postgres.log ||\
        iresult=$?

      if [ -z "$iresult" ]; then
        iresult=0
      fi

      iversion=`cat log/mojo_postgres.log`

      if [ -n "$iversion" ]; then
        echo "$iversion [Code: '$iresult']"
      else
        echo "NONE [Code: '$iresult']"

        #Trigger cpanm Installation
        icpanm=1
      fi  #if [ -n "$iversion" ]; then
      ;;

    es)
      #Checking Dependencies for Elasticsearch Backend

      echo -n "Search::Elasticsearch Version: "

      perl -MSearch::Elasticsearch -e 'print $Search::Elasticsearch::VERSION; ' 2>/dev/null 1>log/perl_elasticsearch.log ||\
        iresult=$?

      if [ -z "$iresult" ]; then
        iresult=0
      fi

      iversion=`cat log/perl_elasticsearch.log`

      if [ -n "$iversion" ]; then
        echo "$iversion [Code: '$iresult']"
      else
        echo "NONE [Code: '$iresult']"

        #Trigger cpanm Installation
        icpanm=1
      fi  #if [ -n "$iversion" ]; then
      ;;

  esac  #case "$backend" in

  if [ "$2" = "install" ]; then
    #Checking Dependencies for Perl Versions Installation

    #Enabling cpanm Feature
    sfeatures="$sfeatures install"

    echo -n "Perl::Build Version: "

    perl -MPerl::Build -e 'print $Perl::Build::VERSION; ' 2>/dev/null 1>log/perl_build.log ||\
      iresult=$?

    if [ -z "$iresult" ]; then
      iresult=0
    fi

    iversion=`cat log/perl_build.log`

    if [ -n "$iversion" ]; then
      echo "$iversion [Code: '$iresult']"
    else
      echo "NONE [Code: '$iresult']"

      #Trigger cpanm Installation
      icpanm=1
    fi  #if [ -n "$iversion" ]; then
  fi  #if [ "$1" = "install" ]; then

  if [ $icpanm -eq 1 ]; then
    #Run cpanm Installation
    echo "Installing Dependencies with cpanm ..."

    for feat in "$sfeatures"; do
      sfeatoptions+=" --with-feature=$feat"
    done

    date +"%s" > log/cpanm_install_$(date +"%F").log
    cpanm -vn --installdeps$sfeatoptions . 2>&1 >> log/cpanm_install_$(date +"%F").log
    cpanmrs=$?
    date +"%s" >> log/cpanm_install_$(date +"%F").log

    echo "Installation finished with [$cpanmrs]"
  fi  #if [ $icpanm -eq 1 ]; then


  echo "Service '$1': Launching ..."

  #Executing the Mojolicious Application
  exec ./$@

fi  #if [ "$1" = "perldoc-browser.pl" ]; then


#Launching any other Command
exec $@
