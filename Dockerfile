FROM ubuntu:14.04

MAINTAINER Ray Burgemeestre

RUN apt-get update
RUN apt-get install -y apache2 php5 php5-gd php5-sqlite apache2-utils
RUN apt-get install -y rsync vim wget telnet make
RUN apt-get install -y openssl libssl-dev
#nagiosgraph
RUN apt-get install -y libcgi-pm-perl librrds-perl libgd-gd2-perl libnagios-object-perl
#livestatus
RUN apt-get install -y aptitude

RUN a2enmod rewrite
RUN a2enmod cgi

ENV nagvis nagvis-1.8.3
ENV nagios nagios-4.0.8
ENV nagiosplugins nagios-plugins-2.0.3
ENV nagiosgraphversion 1.5.2
ENV livestatusversion 1.2.6p2

WORKDIR /usr/local/src
RUN wget http://www.nagvis.org/share/${nagvis}.tar.gz
RUN wget http://prdownloads.sourceforge.net/sourceforge/nagios/${nagios}.tar.gz
RUN wget http://nagios-plugins.org/download/${nagiosplugins}.tar.gz
RUN wget http://downloads.sourceforge.net/project/nagiosgraph/nagiosgraph/${nagiosgraphversion}/nagiosgraph-${nagiosgraphversion}.tar.gz
RUN wget https://mathias-kettner.de/support/${livestatusversion}/check-mk-raw-${livestatusversion}.cre.demo.tar.gz
RUN tar -zxvf check-mk-raw-${livestatusversion}.cre.demo.tar.gz
RUN tar -zxvf ${nagios}.tar.gz
RUN tar -zxvf ${nagvis}.tar.gz
RUN tar -zxvf ${nagiosplugins}.tar.gz
RUN tar -zxvf nagiosgraph-${nagiosgraphversion}.tar.gz

# add nagios user and make it part of nagioscmd group (together with www-data)
RUN useradd -ms /bin/bash nagios
RUN groupadd nagcmd
RUN usermod -a -G nagcmd nagios
RUN usermod -a -G nagcmd www-data

WORKDIR /usr/local/src/${nagios}
RUN ./configure --with-command-group=nagcmd
RUN make all
RUN make install
RUN make install-init
RUN make install-config
RUN make install-commandmode
RUN /usr/bin/install -c -m 644 sample-config/httpd.conf /etc/apache2/sites-enabled/nagios.conf
RUN echo -n admin | htpasswd -i -c /usr/local/nagios/etc/htpasswd.users nagiosadmin

WORKDIR /usr/local/src/check-mk-raw-${livestatusversion}.cre.demo
RUN ./configure --with-nagios4
RUN make
# however, specifically make mk-livestatus package again with the --with-nagios4 flag!
WORKDIR /usr/local/src/check-mk-raw-${livestatusversion}.cre.demo/packages/mk-livestatus/mk-livestatus-${livestatusversion}
# is this necessary?? RUN make clean
RUN ./configure --with-nagios4
RUN make
RUN make install

WORKDIR /usr/local/src/${nagiosplugins}
RUN ./configure --with-nagios-user=nagios --with-nagios-group=nagios --with-openssl
RUN make
RUN make install

WORKDIR /usr/local/src/${nagvis}
# update nagios config
RUN echo "broker_module=/usr/local/lib/mk-livestatus/livestatus.o /usr/local/nagios/var/rw/live" >> /usr/local/nagios/etc/nagios.cfg
RUN echo "process_performance_data=1" >> /usr/local/nagios/etc/nagios.cfg
RUN echo "service_perfdata_file=/usr/local/nagios/var/perfdata.log" >> /usr/local/nagios/etc/nagios.cfg
RUN echo "service_perfdata_file_template=\$LASTSERVICECHECK\$||\$HOSTNAME\$||\$SERVICEDESC\$||\$SERVICEOUTPUT\$||\$SERVICEPERFDATA\$" >> /usr/local/nagios/etc/nagios.cfg
RUN echo "service_perfdata_file_mode=a" >> /usr/local/nagios/etc/nagios.cfg
RUN echo "service_perfdata_file_processing_interval=30" >> /usr/local/nagios/etc/nagios.cfg
RUN echo "service_perfdata_file_processing_command=process-service-perfdata" >> /usr/local/nagios/etc/nagios.cfg
# call installation script
RUN ./install.sh -n /usr/local/nagios -p /usr/local/nagvis -l "unix:/usr/local/nagios/var/rw/live" -b mklivestatus -u www-data -g www-data -w /etc/apache2/conf-enabled -a y -F -q
# fix nagvis apache vhost
RUN echo "<Directory \"/usr/local/nagvis/share\">" >> /etc/apache2/conf-enabled/nagvis.conf
RUN echo "  Require all granted"                   >> /etc/apache2/conf-enabled/nagvis.conf
RUN echo "</Directory>"                            >> /etc/apache2/conf-enabled/nagvis.conf

WORKDIR /usr/local/src/nagiosgraph-${nagiosgraphversion}
RUN ./install.pl --check-prereq
RUN NG_PREFIX=/usr/local/nagiosgraph NG_WWW_DIR=/usr/local/nagios/share ./install.pl --prefix=/usr/local/nagiosgraph
# fix nagiosgraph vhost
RUN cp -prv /usr/local/nagiosgraph/etc/nagiosgraph-apache.conf /etc/apache2/sites-enabled/
RUN echo "<Directory \"/usr/local/nagiosgraph/cgi/\">" >> /etc/apache2/sites-enabled/nagiosgraph-apache.conf
RUN echo "  Require all granted"                       >> /etc/apache2/sites-enabled/nagiosgraph-apache.conf
RUN echo "</Directory>"                                >> /etc/apache2/sites-enabled/nagiosgraph-apache.conf
# define a graphed-service service template
RUN echo "define service {" >>/usr/local/nagios/etc/objects/templates.cfg
RUN echo "    name graphed-service" >>/usr/local/nagios/etc/objects/templates.cfg
RUN echo "    action_url /nagiosgraph/cgi-bin/show.cgi?host=\$HOSTNAME\$&service=\$SERVICEDESC\$' onMouseOver='showGraphPopup(this)' onMouseOut='hideGraphPopup()' rel='/nagiosgraph/cgi-bin/showgraph.cgi?host=\$HOSTNAME\$&service=\$SERVICEDESC\$&period=week&rrdopts=-w+450+-j" >>/usr/local/nagios/etc/objects/templates.cfg
RUN echo "    register 0" >>/usr/local/nagios/etc/objects/templates.cfg
RUN echo "}" >>/usr/local/nagios/etc/objects/templates.cfg
# for demo enable the graphed-service on all the services in localhost.cfg
RUN sed -i 's/local-service/local-service,graphed-service/' /usr/local/nagios/etc/objects/localhost.cfg
# fix the perfdata log location in nagiosgraph.conf
RUN sed -i 's/\/tmp\/perfdata.log/\/usr\/local\/nagios\/var\/perfdata.log/' /usr/local/nagiosgraph/etc/nagiosgraph.conf
# replace the process-service-perfdata command (renames the old one to *-old, which is an artifact from the install.sh script run previously)
RUN sed -i 's/process-service-perfdata/process-service-perfdata-old/' /usr/local/nagios/etc/objects/commands.cfg
RUN echo 'define command {'                                      >> /usr/local/nagios/etc/objects/commands.cfg
RUN echo '   command_name  process-service-perfdata'             >> /usr/local/nagios/etc/objects/commands.cfg
RUN echo '   command_line  /usr/local/nagiosgraph/bin/insert.pl' >> /usr/local/nagios/etc/objects/commands.cfg
RUN echo '}'                                                     >> /usr/local/nagios/etc/objects/commands.cfg

# create a user-friendly index.html for default vhost
RUN echo '<a href="/nagios/">nagios (l: nagiosadmin, p:admin)</a> <br/>'  > /var/www/html/index.html
RUN echo '<a href="/nagvis/">nagvis (l: admin, p:admin)</a> <br/>'       >> /var/www/html/index.html
RUN echo '<a href="/nagiosgraph/cgi-bin/show.cgi">nagiosgraph</a> <br/>' >> /var/www/html/index.html

EXPOSE 80

# create a script that starts both apache and the nagios process
RUN echo "/usr/sbin/apache2ctl start"                                     > /usr/bin/start-apache-and-nagios.sh
RUN echo "/usr/local/nagios/bin/nagios /usr/local/nagios/etc/nagios.cfg" >> /usr/bin/start-apache-and-nagios.sh

ENTRYPOINT ["/bin/bash", "/usr/bin/start-apache-and-nagios.sh"]
