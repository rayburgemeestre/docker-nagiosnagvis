FROM ubuntu:14.04

MAINTAINER Ray Burgemeestre

ENV nagvis nagvis-1.8.3
ENV nagios nagios-4.0.8
ENV nagiosplugins nagios-plugins-2.0.3
ENV nagiosgraphversion 1.5.2
ENV livestatusversion 1.2.6p2

RUN apt-get update && \
    ### apache and php and other prerequisites \
    apt-get install -y apache2 php5 php5-gd php5-sqlite apache2-utils && \
    apt-get install -y rsync vim wget telnet make && \
    ### nagios plugins ssl support \
    apt-get install -y openssl libssl-dev && \
    \
    ### nagiosgraph dependencies.. \
    apt-get install -y libcgi-pm-perl librrds-perl libgd-gd2-perl libnagios-object-perl && \
    \
    ### livestatus.. \
    apt-get install -y aptitude && \
    \
    ### enable apache modules.. \
    a2enmod rewrite && \
    a2enmod cgi && \
    \
    ### add nagios (and www-data) user and make them part of nagioscmd group \
    useradd -ms /bin/bash nagios && \
    groupadd nagcmd && \
    usermod -a -G nagcmd nagios && \
    usermod -a -G nagcmd www-data

WORKDIR /usr/local/src
RUN wget http://www.nagvis.org/share/${nagvis}.tar.gz && \
    wget http://prdownloads.sourceforge.net/sourceforge/nagios/${nagios}.tar.gz && \
    wget http://nagios-plugins.org/download/${nagiosplugins}.tar.gz && \
    wget http://downloads.sourceforge.net/project/nagiosgraph/nagiosgraph/${nagiosgraphversion}/nagiosgraph-${nagiosgraphversion}.tar.gz && \
    wget https://mathias-kettner.de/support/${livestatusversion}/check-mk-raw-${livestatusversion}.cre.demo.tar.gz && \
    tar -zxvf check-mk-raw-${livestatusversion}.cre.demo.tar.gz && \
    tar -zxvf ${nagios}.tar.gz && \
    tar -zxvf ${nagvis}.tar.gz && \
    tar -zxvf ${nagiosplugins}.tar.gz && \
    tar -zxvf nagiosgraph-${nagiosgraphversion}.tar.gz

WORKDIR /usr/local/src/${nagios}
RUN ./configure --with-command-group=nagcmd && \
    make all && \
    make install && \
    make install-init && \
    make install-config && \
    make install-commandmode && \
    /usr/bin/install -c -m 644 sample-config/httpd.conf /etc/apache2/sites-enabled/nagios.conf && \
    echo -n admin | htpasswd -i -c /usr/local/nagios/etc/htpasswd.users nagiosadmin

WORKDIR /usr/local/src/check-mk-raw-${livestatusversion}.cre.demo
RUN ./configure --with-nagios4 && \
    make && \
    ### specifically make mk-livestatus package /again/ with the --with-nagios4 flag, by default it's build for nagios3 which doesn't work.. \
    cd ./packages/mk-livestatus/mk-livestatus-${livestatusversion} && \
    make clean && \
    ./configure --with-nagios4 && \
    make && \
    make install

WORKDIR /usr/local/src/${nagiosplugins}
RUN ./configure --with-nagios-user=nagios --with-nagios-group=nagios --with-openssl && \
    make && \
    make install

WORKDIR /usr/local/src/${nagvis}
RUN \
    ### update nagios config.. \
    echo "broker_module=/usr/local/lib/mk-livestatus/livestatus.o /usr/local/nagios/var/rw/live" >> /usr/local/nagios/etc/nagios.cfg && \
    echo "process_performance_data=1" >> /usr/local/nagios/etc/nagios.cfg && \
    echo "service_perfdata_file=/usr/local/nagios/var/perfdata.log" >> /usr/local/nagios/etc/nagios.cfg && \
    echo "service_perfdata_file_template=\$LASTSERVICECHECK\$||\$HOSTNAME\$||\$SERVICEDESC\$||\$SERVICEOUTPUT\$||\$SERVICEPERFDATA\$" >> /usr/local/nagios/etc/nagios.cfg && \
    echo "service_perfdata_file_mode=a" >> /usr/local/nagios/etc/nagios.cfg && \
    echo "service_perfdata_file_processing_interval=30" >> /usr/local/nagios/etc/nagios.cfg && \
    echo "service_perfdata_file_processing_command=process-service-perfdata" >> /usr/local/nagios/etc/nagios.cfg && \
    ### call installation script \
    ./install.sh -n /usr/local/nagios -p /usr/local/nagvis -l "unix:/usr/local/nagios/var/rw/live" -b mklivestatus -u www-data -g www-data -w /etc/apache2/conf-enabled -a y -F -q && \
    ### fix nagvis apache vhost \
    echo "<Directory \"/usr/local/nagvis/share\">" >> /etc/apache2/conf-enabled/nagvis.conf && \
    echo "  Require all granted"                   >> /etc/apache2/conf-enabled/nagvis.conf && \
    echo "</Directory>"                            >> /etc/apache2/conf-enabled/nagvis.conf

WORKDIR /usr/local/src/nagiosgraph-${nagiosgraphversion}
RUN ./install.pl --check-prereq && \
    NG_PREFIX=/usr/local/nagiosgraph NG_WWW_DIR=/usr/local/nagios/share ./install.pl --prefix=/usr/local/nagiosgraph && \
    \
    ### fix nagiosgraph vhost \
    cp -prv /usr/local/nagiosgraph/etc/nagiosgraph-apache.conf /etc/apache2/sites-enabled/ && \
    echo "<Directory \"/usr/local/nagiosgraph/cgi/\">" >> /etc/apache2/sites-enabled/nagiosgraph-apache.conf && \
    echo "  Require all granted"                       >> /etc/apache2/sites-enabled/nagiosgraph-apache.conf && \
    echo "</Directory>"                                >> /etc/apache2/sites-enabled/nagiosgraph-apache.conf && \
    \
    ### define a graphed-service service template \
    echo "define service {" >>/usr/local/nagios/etc/objects/templates.cfg && \
    echo "    name graphed-service" >>/usr/local/nagios/etc/objects/templates.cfg && \
    echo "    action_url /nagiosgraph/cgi-bin/show.cgi?host=\$HOSTNAME\$&service=\$SERVICEDESC\$' onMouseOver='showGraphPopup(this)' onMouseOut='hideGraphPopup()' rel='/nagiosgraph/cgi-bin/showgraph.cgi?host=\$HOSTNAME\$&service=\$SERVICEDESC\$&period=week&rrdopts=-w+450+-j" >>/usr/local/nagios/etc/objects/templates.cfg && \
    echo "    register 0" >>/usr/local/nagios/etc/objects/templates.cfg && \
    echo "}" >>/usr/local/nagios/etc/objects/templates.cfg && \
    \
    ### for demo enable the graphed-service on all the services in localhost.cfg \
    sed -i 's/local-service/local-service,graphed-service/' /usr/local/nagios/etc/objects/localhost.cfg && \
    \
    ### fix the perfdata log location in nagiosgraph.conf \
    sed -i 's/\/tmp\/perfdata.log/\/usr\/local\/nagios\/var\/perfdata.log/' /usr/local/nagiosgraph/etc/nagiosgraph.conf && \
    \
    ### replace the process-service-perfdata command (renames the old one to *-old, which is an artifact from the install.sh script run previously) \
    sed -i 's/process-service-perfdata/process-service-perfdata-old/' /usr/local/nagios/etc/objects/commands.cfg && \
    echo 'define command {'                                      >> /usr/local/nagios/etc/objects/commands.cfg && \
    echo '   command_name  process-service-perfdata'             >> /usr/local/nagios/etc/objects/commands.cfg && \
    echo '   command_line  /usr/local/nagiosgraph/bin/insert.pl' >> /usr/local/nagios/etc/objects/commands.cfg && \
    echo '}'                                                     >> /usr/local/nagios/etc/objects/commands.cfg

RUN \
    ### create a user-friendly index.html for default vhost \
    echo '<a href="/nagios/">nagios (l: nagiosadmin, p:admin)</a> <br/>'  > /var/www/html/index.html &&\
    echo '<a href="/nagvis/">nagvis (l: admin, p:admin)</a> <br/>'       >> /var/www/html/index.html &&\
    echo '<a href="/nagiosgraph/cgi-bin/show.cgi">nagiosgraph</a> <br/>' >> /var/www/html/index.html &&\
    \
    ### create a script that starts both apache and the nagios process \
    echo "/usr/sbin/apache2ctl start"                                     > /usr/bin/start-apache-and-nagios.sh &&\
    echo "/usr/local/nagios/bin/nagios /usr/local/nagios/etc/nagios.cfg" >> /usr/bin/start-apache-and-nagios.sh

EXPOSE 80

ENTRYPOINT ["/bin/bash", "/usr/bin/start-apache-and-nagios.sh"]
