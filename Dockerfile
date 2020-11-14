FROM debian:buster
RUN apt-get update &&\
  apt-get -y install apt-utils gcc make openssl &&\
  apt-get -y install cpanminus perl-modules liblocal-lib-perl &&\
  apt-get -y install libdbi-perl libfile-pushd-perl libipc-run3-perl libmodule-runtime-perl libsort-versions-perl libdevel-patchperl-perl libmodule-build-tiny-perl libmodule-pluggable-perl\
    libsyntax-keyword-try-perl libcapture-tiny-perl libhttp-tinyish-perl libnet-ssleay-perl\
    liburl-encode-perl libextutils-config-perl libextutils-helpers-perl libextutils-installpaths-perl\
    libclone-choose-perl libhash-merge-perl libtest-deep-perl liburi-nested-perl\
    libsql-abstract-perl liburi-db-perl libdbd-sqlite3-perl
COPY etc/docker/entrypoint.sh /usr/local/bin/
RUN chmod a+x /usr/local/bin/entrypoint.sh\
  && ln -s /usr/local/bin/entrypoint.sh /entrypoint.sh # backwards compat
RUN groupadd web &&\
  useradd per1_web -g web -md /home/perldoc-browser -s /sbin/nologin &&\
  chmod a+rx /home/perldoc-browser
VOLUME /home/perldoc-browser
USER per1_web
WORKDIR /home/perldoc-browser
ENTRYPOINT ["entrypoint.sh"]
CMD ["perldoc-browser.pl", "prefork"]
