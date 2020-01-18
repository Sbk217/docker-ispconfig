#
#                    ##        .
#              ## ## ##       ==
#           ## ## ## ##      ===
#       /""""""""""""""""\___/ ===
#  ~~~ {~~ ~~~~ ~~~ ~~~~ ~~ ~ /  ===- ~~~
#       \______ o          __/
#         \    \        __/
#          \____\______/
#
#          |          |
#       __ |  __   __ | _  __   _
#      /  \| /  \ /   |/  / _\ |
#      \__/| \__/ \__ |\_ \__  |
#
# Dockerfile for ISPConfig with MariaDB database
#
# Originally based on:
# https://www.howtoforge.com/tutorial/perfect-server-debian-9-stretch-apache-bind-dovecot-ispconfig-3-1/
#
FROM debian:buster-slim

LABEL maintainer="jon.crooke@gmail.com"
LABEL description="ISPConfig 3.1 on Debian Buster, with Roundcube mail, phpMyAdmin and more"

# All arguments
ARG BUILD_CERTBOT="yes"
ARG BUILD_HOSTNAME="myhost.test.com"
ARG BUILD_ISPCONFIG_VERSION="3.1.15p2"
ARG BUILD_ISPCONFIG_DROP_EXISTING="no"
ARG BUILD_ISPCONFIG_MYSQL_DATABASE="dbispconfig"
ARG BUILD_ISPCONFIG_PORT="8080"
ARG BUILD_ISPCONFIG_USE_SSL="yes"
ARG BUILD_LOCALE="en_US"
ARG BUILD_MYSQL_HOST="localhost"
ARG BUILD_MYSQL_PW="pass"
ARG BUILD_MYSQL_REMOTE_ACCESS_HOST="172.%.%.%"
ARG BUILD_PHPMYADMIN="yes"
ARG BUILD_PHPMYADMIN_PW="phpmyadmin"
ARG BUILD_PHPMYADMIN_USER="phpmyadmin"
ARG BUILD_PHPMYADMIN_VERSION="4.9.1"
ARG BUILD_PRINTING="no"
ARG BUILD_REDIS="yes"
ARG BUILD_ROUNDCUBE_VERSION="1.4.2"
ARG BUILD_ROUNDCUBE_DB="roundcube"
ARG BUILD_ROUNDCUBE_DIR="/opt/roundcube"
ARG BUILD_ROUNDCUBE_PW="secretpassword"
ARG BUILD_ROUNDCUBE_USER="roundcube"
ARG BUILD_TZ="Europe/Berlin"

# Let the container know that there is no tty
ENV DEBIAN_FRONTEND noninteractive

# --- set timezone and locale
RUN apt-get -y update && \
    apt-get -y --no-install-recommends install locales && \
    sed -i -e "s/# ${BUILD_LOCALE}.UTF-8 UTF-8/${BUILD_LOCALE}.UTF-8 UTF-8/" /etc/locale.gen && \
    locale-gen
ENV LANG "${BUILD_LOCALE}.UTF-8"
ENV LANGUAGE "${BUILD_LOCALE}:en"
ENV LC_ALL "${BUILD_LOCALE}.UTF-8"
RUN ln -fs /usr/share/zoneinfo/${BUILD_TZ} /etc/localtime; \
    dpkg-reconfigure -f noninteractive tzdata; \
# --- 1 Preliminary
    apt-get -y --no-install-recommends install cron rsyslog rsyslog-relp logrotate supervisor git sendemail rsnapshot wget sudo; \
    ln -s /usr/bin/true /usr/bin/systemctl; \
# Create the log file to be able to run tail
    touch /var/log/cron.log; \
    touch /var/spool/cron/root; \
    crontab /var/spool/cron/root; \
# --- 2 Install the SSH server
    apt-get -y --no-install-recommends install ssh openssh-server rsync; \
# --- 3 Install a shell text editor
    apt-get -y --no-install-recommends install nano vim-nox; \
# --- 5 Update Your Debian Installation
    apt-get -y update && apt-get -y upgrade; \
# --- 6 Change The Default Shell
    echo "dash  dash/sh boolean no" | debconf-set-selections; \
    dpkg-reconfigure dash; \
# --- 7 Synchronize the System Clock
    apt-get -y --no-install-recommends install ntp ntpdate; \
# --- 8 Install MySQL (optional)
    apt-get -y --no-install-recommends install mariadb-client; \
    if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then \
        echo "mariadb-server mariadb-server/root_password password ${BUILD_MYSQL_PW}"       | debconf-set-selections; \
        echo "mariadb-server mariadb-server/root_password_again password ${BUILD_MYSQL_PW}" | debconf-set-selections; \
        apt-get -y --no-install-recommends install mariadb-server; \
    fi
ADD ./build/etc/mysql/debian.cnf /etc/mysql
ADD ./build/etc/mysql/50-server.cnf /etc/mysql/mariadb.conf.d/
RUN \
    if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then \
        sed -i "s|password =|password = ${BUILD_MYSQL_PW}|" /etc/mysql/debian.cnf; \
        echo "mysql soft nofile 65535\nmysql hard nofile 65535\n" >> /etc/security/limits.conf; \
        mkdir -p /etc/systemd/system/mysql.service.d/; \
        echo "[Service]\nLimitNOFILE=infinity\n" >> /etc/systemd/system/mysql.service.d/limits.conf; \
    fi; \
    if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then \
        service mysql restart; \
        echo "UPDATE mysql.user SET plugin = 'mysql_native_password', Password = PASSWORD('${BUILD_MYSQL_PW}') WHERE User = 'root';" | mysql -h ${BUILD_MYSQL_HOST} -uroot -p${BUILD_MYSQL_PW}; \
    elif ! mysql -h ${BUILD_MYSQL_HOST} -uroot -p${BUILD_MYSQL_PW}; then \
        echo "\e[31mConnection to mysql host \"${BUILD_MYSQL_HOST}\" failed!\e[0m"; \
        exit 1; \
    fi; \
# --- 8 Install Postfix, Dovecot, rkhunter, binutils
    apt-get -y --no-install-recommends install postfix postfix-mysql postfix-doc libsasl2-modules openssl getmail4 binutils dovecot-imapd dovecot-pop3d dovecot-mysql dovecot-sieve dovecot-lmtpd
ADD ./build/etc/postfix/master.cf /etc/postfix/master.cf

RUN service postfix restart; \
    if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then service mysql restart; fi; \
# --- 9 Install SpamAssassin And Clamav
    (crontab -l; echo "") | sort - | uniq - | crontab -; \
    apt-get -y --no-install-recommends install spamassassin sa-compile clamav clamav-daemon gpg gpg-agent unzip bzip2 arj nomarch lzop cabextract apt-listchanges libnet-ldap-perl libauthen-sasl-perl clamav-docs daemon libio-string-perl libio-socket-ssl-perl libnet-ident-perl zip libnet-dns-perl libdbd-mysql-perl postgrey gpgv1 gnupg1

ADD ./build/etc/clamav/clamd.conf /etc/clamav/clamd.conf
RUN (crontab -l; echo "@daily    /usr/bin/freshclam") | sort - | uniq - | crontab -; \
    freshclam; \
    service spamassassin stop; \
    systemctl disable spamassassin; \
    sa-update; sa-compile; \
# --- 10 Install Apache2, PHP5, FCGI, suExec, Pear, And mcrypt
    if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then service mysql restart; fi; \
    apt-get -y --no-install-recommends install apache2 apache2-doc apache2-utils libapache2-mod-php php7.3 php7.3-common php7.3-gd php7.3-mysql php7.3-imap php7.3-cli php7.3-cgi php7.3-bz2 php-apcu php-apcu-bc libapache2-mod-fcgid apache2-suexec-pristine php-pear mcrypt imagemagick libruby libapache2-mod-python php7.3-curl php7.3-intl php7.3-pspell php7.3-recode php7.3-sqlite3 php7.3-tidy php7.3-xmlrpc php7.3-xsl memcached php-memcache php-imagick php-gettext php7.3-zip php7.3-mbstring memcached libapache2-mod-passenger php7.3-soap; \
    apt-get -y --no-install-recommends install -y php php-cgi php-mysqli php-pear php-mbstring php-gettext libapache2-mod-php php-common php-phpseclib php-mysql; \
    /usr/sbin/a2enmod suexec rewrite ssl actions include dav_fs dav auth_digest cgi headers
ADD ./build/etc/apache2/httpoxy.conf /etc/apache2/conf-available/
RUN echo "ServerName ${BUILD_HOSTNAME}" | tee /etc/apache2/conf-available/fqdn.conf; \
	/usr/sbin/a2enconf fqdn; \
    /usr/sbin/a2enconf httpoxy

# --- 10.1 Install phpMyAdmin (optional)
# https://www.linuxbabe.com/debian/install-phpmyadmin-apache-lamp-debian-10-buster
COPY ./build/etc/phpmyadmin/config.inc.php /tmp/phpmyadmin.config.inc.php
COPY ./build/etc/apache2/phpmyadmin.conf /etc/apache2/conf-available/phpmyadmin.conf
RUN \
    if [ "${BUILD_PHPMYADMIN}" = "yes" ]; then \
        if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then \
            wget "https://files.phpmyadmin.net/phpMyAdmin/${BUILD_PHPMYADMIN_VERSION}/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages.zip" -O "/tmp/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages.zip"; \
            unzip "/tmp/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages.zip" -d /usr/share/; \
            mv "/usr/share/phpMyAdmin-${BUILD_PHPMYADMIN_VERSION}-all-languages" /usr/share/phpmyadmin; \
            chown -R www-data:www-data /usr/share/phpmyadmin; \
            service mysql restart; \
            mysql -h ${BUILD_MYSQL_HOST} -uroot -p${BUILD_MYSQL_PW} -e "CREATE DATABASE phpmyadmin DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; \
            mysql -h ${BUILD_MYSQL_HOST} -uroot -p${BUILD_MYSQL_PW} -e "GRANT ALL ON phpmyadmin.* TO '${BUILD_PHPMYADMIN_USER}'@'localhost' IDENTIFIED BY '${BUILD_PHPMYADMIN_PW}';"; \
            apt-get -y --no-install-recommends install php-imagick php-phpseclib php-php-gettext php7.3-common php7.3-mysql php7.3-gd php7.3-imap php7.3-json php7.3-curl php7.3-zip php7.3-xml php7.3-mbstring php7.3-bz2 php7.3-intl php7.3-gmp ;\
            /usr/sbin/a2enconf phpmyadmin.conf; \
            mv /tmp/phpmyadmin.config.inc.php /usr/share/phpmyadmin/config.inc.php; \
            sed -i "s|\['controlhost'\] = '';|\['controlhost'\] = '${BUILD_MYSQL_HOST}';|" /usr/share/phpmyadmin/config.inc.php; \
            sed -i "s|\['controluser'\] = '';|\['controluser'\] = '${BUILD_PHPMYADMIN_USER}';|" /usr/share/phpmyadmin/config.inc.php; \
            sed -i "s|\['controlpass'\] = '';|\['controlpass'\] = '${BUILD_PHPMYADMIN_PW}';|" /usr/share/phpmyadmin/config.inc.php; \
            mkdir -p /var/lib/phpmyadmin/tmp; \
            chown www-data:www-data /var/lib/phpmyadmin/tmp; \
            service apache2 restart; \
            service apache2 reload; \
        else \
            echo "\e[31m'BUILD_PHPMYADMIN' = 'yes', but 'BUILD_MYSQL_HOST' is not 'localhost' ('${BUILD_MYSQL_HOST}')\e[0m"; \
            echo "\e[31mCan't currently install phpMyAdmin with a remote server connection. Sorry!\e[0m"; \
        fi; \
    fi; \
    service apache2 restart; \
# --- 11 Free SSL RUN mkdir /opt/certbot
    if [ "${BUILD_CERTBOT}" = "yes" ]; then apt-get -y --no-install-recommends install certbot; fi; \
# --- 12 PHP-FPM
    apt-get -y --no-install-recommends install php7.3-fpm; \
    /usr/sbin/a2enmod actions proxy_fcgi alias setenvif; \
    /usr/sbin/a2enconf php7.3-fpm; \
    service apache2 restart; \
# --- 12.2 Opcode Cache
    apt-get -y --no-install-recommends install php7.3-opcache php-apcu; service apache2 restart; \
# --- 13 Install Mailman
# Doesn't really work (yet)
    echo 'mailman mailman/default_server_language select en' | debconf-set-selections; \
    apt-get -y --no-install-recommends install mailman
# RUN ["/usr/lib/mailman/bin/newlist", "-q", "mailman", "mail@mail.com", "pass"]
ADD ./build/etc/aliases /etc/aliases
RUN newaliases; \
    service postfix restart; \
    ln -s /etc/mailman/apache.conf /etc/apache2/conf-enabled/mailman.conf; \
# --- 14 Install PureFTPd
    apt-get -y --no-install-recommends install pure-ftpd-common pure-ftpd-mysql; \
    groupadd ftpgroup; \
    useradd -g ftpgroup -d /dev/null -s /etc ftpuser
ADD ./build/etc/default/pure-ftpd-common /etc/default/pure-ftpd-common

# --- 15 Install BIND DNS Server, haveged, unbound, rspamd
RUN apt-get -y --no-install-recommends install haveged unbound lsb-release; \
    echo "do-ip6: no" > /etc/unbound/unbound.conf.d/no-ip6v.conf; \
    if [ "$BUILD_REDIS" = "yes" ]; then \
        apt-get -y --no-install-recommends install redis-server; \
        sed -i "s|daemonize yes|daemonize no|" /etc/redis/redis.conf; \
    fi; \
    CODENAME=`lsb_release -c -s`; \
    wget -O- https://rspamd.com/apt-stable/gpg.key | apt-key add - ; \
    echo "deb [arch=amd64] http://rspamd.com/apt-stable/ $CODENAME main" > /etc/apt/sources.list.d/rspamd.list; \
    echo "deb-src [arch=amd64] http://rspamd.com/apt-stable/ $CODENAME main" >> /etc/apt/sources.list.d/rspamd.list; \
    apt-get update && apt-get -y --no-install-recommends install rspamd; \
    echo "servers = \"localhost\";" > /etc/rspamd/local.d/redis.conf; \
    echo "nrows = 2500;" > /etc/rspamd/local.d/history_redis.conf; \
    echo "compress = true;" >> /etc/rspamd/local.d/history_redis.conf; \
    echo "subject_privacy = false;" >> /etc/rspamd/local.d/history_redis.conf; \
    sed -i 's|-f /bin/systemctl|-d /run/systemd/system|' /etc/logrotate.d/rspamd; \
# --- 16 Install Vlogger, Webalizer, And AWStats
    apt-get -y --no-install-recommends install webalizer awstats geoip-database libclass-dbi-mysql-perl libtimedate-perl
ADD ./build/etc/cron.d/awstats /etc/cron.d/

# --- 17 Install Jailkit
# install package building helpers
RUN apt-get -y --no-install-recommends install build-essential autoconf automake libtool flex bison debhelper binutils; \
    cd /tmp; \
    wget http://olivier.sessink.nl/jailkit/jailkit-2.19.tar.gz; \
    tar xvfz jailkit-2.19.tar.gz; \
    cd jailkit-2.19; echo 5 > debian/compat; \
    ./debian/rules binary; \
    cd ..; \
    dpkg -i jailkit_2.19-1_*.deb; \
    rm -rf jailkit-2.19*; \
# --- 18 Install fail2ban
    apt-get -y --no-install-recommends install fail2ban
ADD ./build/etc/fail2ban/jail.local /etc/fail2ban/jail.local
ADD ./build/etc/fail2ban/filter.d/pureftpd.conf /etc/fail2ban/filter.d/pureftpd.conf
ADD ./build/etc/fail2ban/filter.d/dovecot-pop3imap.conf /etc/fail2ban/filter.d/dovecot-pop3imap.conf
RUN touch /var/log/auth.log; \
    touch /var/log/mail.log; \
    touch /var/log/syslog; \
    echo "ignoreregex =" >> /etc/fail2ban/filter.d/postfix-sasl.conf; \
    service fail2ban restart; \
# --- 19 Install roundcube
    mkdir ${BUILD_ROUNDCUBE_DIR}; \
	cd ${BUILD_ROUNDCUBE_DIR}; \
    wget https://github.com/roundcube/roundcubemail/releases/download/${BUILD_ROUNDCUBE_VERSION}/roundcubemail-${BUILD_ROUNDCUBE_VERSION}-complete.tar.gz; \
    tar xfz roundcubemail-${BUILD_ROUNDCUBE_VERSION}-complete.tar.gz; \
	mv roundcubemail-${BUILD_ROUNDCUBE_VERSION}/* .; \
    mv roundcubemail-${BUILD_ROUNDCUBE_VERSION}/.htaccess .; \
    rmdir roundcubemail-${BUILD_ROUNDCUBE_VERSION}; \
	rm roundcubemail-${BUILD_ROUNDCUBE_VERSION}-complete.tar.gz; \
    chown -R www-data:www-data ${BUILD_ROUNDCUBE_DIR}; \
    if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then \
        service mysql restart; \
        BUILD_MYSQL_REMOTE_ACCESS_HOST="localhost"; \
    fi; \
    if ! echo "USE ${BUILD_ROUNDCUBE_DB};" | mysql -h "${BUILD_MYSQL_HOST}" -uroot -p"${BUILD_MYSQL_PW}" 2> /dev/null; then \
        echo "CREATE DATABASE ${BUILD_ROUNDCUBE_DB};" | mysql -h ${BUILD_MYSQL_HOST} -uroot -p${BUILD_MYSQL_PW}; \
        mysql -h ${BUILD_MYSQL_HOST} -uroot -p${BUILD_MYSQL_PW} ${BUILD_ROUNDCUBE_DB} < ${BUILD_ROUNDCUBE_DIR}/SQL/mysql.initial.sql; \
    fi; \
    mysql -h ${BUILD_MYSQL_HOST} -uroot -p${BUILD_MYSQL_PW} -e "\
    GRANT ALL PRIVILEGES ON ${BUILD_ROUNDCUBE_DB}.* TO ${BUILD_ROUNDCUBE_USER}@'${BUILD_MYSQL_REMOTE_ACCESS_HOST}' IDENTIFIED BY '${BUILD_ROUNDCUBE_PW}'; \
    FLUSH PRIVILEGES;"; \
    cd ${BUILD_ROUNDCUBE_DIR}/config; \
	cp -pf config.inc.php.sample config.inc.php; \
    sed -i "s|mysql://roundcube:pass@localhost/roundcubemail|mysql://${BUILD_ROUNDCUBE_USER}:${BUILD_ROUNDCUBE_PW}@${BUILD_MYSQL_HOST}/${BUILD_ROUNDCUBE_DB}|" ${BUILD_ROUNDCUBE_DIR}/config/config.inc.php; \
    sed -i "s|\$config\['default_host'\] = '';|\$config\['default_host'\] = 'localhost';|" ${BUILD_ROUNDCUBE_DIR}/config/config.inc.php; \
    sed -i "s|\$config\['smtp_server'\] = '';|\$config\['smtp_server'\] = 'localhost';|" ${BUILD_ROUNDCUBE_DIR}/config/config.inc.php; \
    find "${BUILD_ROUNDCUBE_DIR}" -name ".htaccess" -exec sed -i "s|mod_php5|mod_php7|" {} \;; \
    find "${BUILD_ROUNDCUBE_DIR}" -name ".htaccess" -exec sed -i "s|# php_value    error_log|php_value   date.timezone ${BUILD_TZ}\nphp_value   error_log|" {} \;
ADD ./build/etc/apache2/roundcube.conf /etc/apache2/conf-enabled/roundcube.conf

# --- 19 Install ispconfig plugins for roundcube
RUN git clone https://github.com/w2c/ispconfig3_roundcube.git /tmp/ispconfig3_roundcube/; \
    mv /tmp/ispconfig3_roundcube/ispconfig3_* ${BUILD_ROUNDCUBE_DIR}/plugins; \
	rm -Rvf /tmp/ispconfig3_roundcube; \
    printf "\n\$config['plugins'] = array_merge(\$config['plugins'], array(\"jqueryui\", \"ispconfig3_account\", \"ispconfig3_autoreply\", \"ispconfig3_pass\", \"ispconfig3_spam\", \"ispconfig3_fetchmail\", \"ispconfig3_filter\"));\n" >> ${BUILD_ROUNDCUBE_DIR}/config/config.inc.php; \
    cd ${BUILD_ROUNDCUBE_DIR}/plugins; \
	mv ispconfig3_account/config/config.inc.php.dist ispconfig3_account/config/config.inc.php; \
	chown www-data:www-data ispconfig3_account/config/config.inc.php; \
    chown -R www-data:www-data ${BUILD_ROUNDCUBE_DIR}/plugins/ispconfig3_*; \
# --- 20 Install ISPConfig 3
    cd /tmp; \
	cd .; \
	wget https://ispconfig.org/downloads/ISPConfig-${BUILD_ISPCONFIG_VERSION}.tar.gz; \
    cd /tmp; \
	tar xfz ISPConfig-${BUILD_ISPCONFIG_VERSION}.tar.gz
ADD ./build/autoinstall.ini /tmp/ispconfig3_install/install/autoinstall.ini
RUN touch /etc/mailname; \
    sed -i "s|mysql_hostname=localhost|mysql_hostname=${BUILD_MYSQL_HOST}|" /tmp/ispconfig3_install/install/autoinstall.ini; \
    sed -i "s/^ispconfig_port=8080$/ispconfig_port=${BUILD_ISPCONFIG_PORT}/g" /tmp/ispconfig3_install/install/autoinstall.ini; \
    sed -i "s|mysql_root_password=pass|mysql_root_password=${BUILD_MYSQL_PW}|" /tmp/ispconfig3_install/install/autoinstall.ini; \
    sed -i "s|mysql_database=dbispconfig|mysql_database=${BUILD_ISPCONFIG_MYSQL_DATABASE}|" /tmp/ispconfig3_install/install/autoinstall.ini; \
    sed -i "s/^hostname=server1.example.com$/hostname=${BUILD_HOSTNAME}/g" /tmp/ispconfig3_install/install/autoinstall.ini; \
    sed -i "s/^ssl_cert_common_name=server1.example.com$/ssl_cert_common_name=${BUILD_HOSTNAME}/g" /tmp/ispconfig3_install/install/autoinstall.ini; \
    sed -i "s/^ispconfig_use_ssl=y$/ispconfig_use_ssl=$(echo ${BUILD_ISPCONFIG_USE_SSL} | cut -c1)/g" /tmp/ispconfig3_install/install/autoinstall.ini; \
    if [ "${BUILD_MYSQL_HOST}" = "localhost" ]; then service mysql restart; fi; \
    if echo "USE ${BUILD_ISPCONFIG_MYSQL_DATABASE};" | mysql -h "${BUILD_MYSQL_HOST}" -uroot -p"${BUILD_MYSQL_PW}" 2> /dev/null; then \
        if [ "${BUILD_ISPCONFIG_DROP_EXISTING}" = "yes" ]; then \
            echo "DROP DATABASE ${BUILD_ISPCONFIG_MYSQL_DATABASE};" | mysql -h "${BUILD_MYSQL_HOST}" -uroot -p"${BUILD_MYSQL_PW}"; \
        else \
            echo "\e[31mERROR: ISPConfig database '${BUILD_ISPCONFIG_MYSQL_DATABASE}' already exists and build argument 'BUILD_ISPCONFIG_DROP_EXISTING' = 'no'. Move the existing database aside before continuing\e[0m"; \
	exit 1; \
        fi; \
    fi; \
    if [ $(echo "SELECT EXISTS(SELECT * FROM mysql.user WHERE User = '${BUILD_ISPCONFIG_MYSQL_USER}')" | mysql --skip-column-names -h "${BUILD_MYSQL_HOST}" -uroot -p"${BUILD_MYSQL_PW}" || true) = 1 ]; then \
        if [ "${BUILD_ISPCONFIG_DROP_EXISTING}" = "yes" ]; then \
            echo "DELETE FROM mysql.user WHERE User = \"${BUILD_ISPCONFIG_MYSQL_USER}\"; FLUSH PRIVILEGES;" | mysql -h "${BUILD_MYSQL_HOST}" -uroot -p"${BUILD_MYSQL_PW}"; \
        else \
            echo "\e[31mERROR: ISPConfig user '${BUILD_ISPCONFIG_MYSQL_USER}' already exists and build argument 'BUILD_ISPCONFIG_DROP_EXISTING' = 'no'. Move the existing user aside before continuing\e[0m"; \
	exit 1; \
        fi; \
    fi; \
    php -q /tmp/ispconfig3_install/install/install.php --autoinstall=/tmp/ispconfig3_install/install/autoinstall.ini; \
    if [ "${BUILD_MYSQL_HOST}" != "localhost" ]; then \
    ISP_ADMIN_PASS=$(grep "\$conf\['db_password'\] = '\(.*\)'" /usr/local/ispconfig/interface/lib/config.inc.php | \
      sed "s|\$conf\['db_password'\] = '\(.*\)';|\1|"); \
    mysql -h "${BUILD_MYSQL_HOST}" -uroot -p"${BUILD_MYSQL_PW}" \
      -e "GRANT ALL PRIVILEGES ON dbispconfig.* TO 'ispconfig'@'${BUILD_MYSQL_REMOTE_ACCESS_HOST}' IDENTIFIED BY '$ISP_ADMIN_PASS';"; \
    fi; \
    sed -i "s|NameVirtualHost|#NameVirtualHost|" /etc/apache2/sites-enabled/000-ispconfig.conf; \
    sed -i "s|NameVirtualHost|#NameVirtualHost|" /etc/apache2/sites-enabled/000-ispconfig.vhost; \
################################################################################################
# the key and cert for pure-ftpd should be available :
    if [ -f "/usr/local/ispconfig/interface/ssl/ispserver.key" ] && [ -f "/usr/local/ispconfig/interface/ssl/ispserver.crt" ]; then \
        mkdir -p /etc/ssl/private/; \
        cd /usr/local/ispconfig/interface/ssl; cat ispserver.key ispserver.crt > ispserver.chain; \
        ln -sf /usr/local/ispconfig/interface/ssl/ispserver.chain /etc/ssl/private/pure-ftpd.pem; \
        echo 1 > /etc/pure-ftpd/conf/TLS; \
    fi; \
# --- 23 Install printing stuff
    if [ "$BUILD_PRINTING" = "yes" ]; then \
        apt-get -y --no-install-recommends install --fix-missing -y libdmtx-utils dblatex latex-make cups-client lpr; \
    fi; \
#
# docker-extensions
#
    mkdir -p /usr/local/bin
COPY ./build/bin/* /usr/local/bin/
RUN chmod a+x /usr/local/bin/*

#
# establish supervisord
#
ADD ./build/supervisor /etc/supervisor
ADD ./build/etc/init.d /etc/init.d

# link old /etc/init.d/ startup scripts to supervisor
RUN ls -m1 /etc/supervisor/services.d | while read i; do mv /etc/init.d/$i /etc/init.d/$i-orig 2> /dev/null; ln -sf /etc/supervisor/super-init.sh /etc/init.d/$i; done; \
    ln -sf /etc/supervisor/systemctl /bin/systemctl; \
    chmod a+x /etc/supervisor/* /etc/supervisor/*.d/*
COPY ./build/supervisor/invoke-rc.d /usr/sbin/invoke-rc.d
#
# create directory for service volume
#
RUN mkdir -p /service ; chmod a+rwx /service
ADD ./build/track.gitignore /.gitignore

#
# Create bootstrap archives
#
RUN cp -v /etc/passwd /etc/passwd.bootstrap; \
    cp -v /etc/shadow /etc/shadow.bootstrap; \
    cp -v /etc/group  /etc/group.bootstrap; \
    mkdir -p /bootstrap; \
    mkdir -p /var/vmail; \
    tar -C /var/vmail -czf /bootstrap/vmail.tgz .; \
    tar -C /var/www -czf /bootstrap/www.tgz  .
ENV TERM xterm

RUN echo "export TERM=xterm" >> /root/.bashrc; \
#
# Tidy up
    apt-get autoremove; \
    rm -rf /tmp/*

EXPOSE 20 21 22 53/udp 53/tcp 80 443 953 8080 30000 30001 30002 30003 30004 30005 30006 30007 30008 30009 3306

HEALTHCHECK --start-period=2m --timeout=3s --retries=1 \
  CMD sh -c '! supervisorctl status all | grep -E "STARTING|FATAL"'

#
# startup script
#
ADD ./build/start.sh /start.sh
RUN chmod 755 /start.sh
CMD ["/start.sh"]
