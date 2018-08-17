**[Back to MySQL HOWTO's](https://github.com/wwwted/MySQL-HOWTOs)**

# MySQL-InnoDB-Cluster-3VM-Setup
![](./img/Mysql_idc.jpg)

In this exercise we will build and test a InnoDB Cluster on 3 servers, virtual or real it's your choice.

You can use any technology you like, I use VirtualBox in this workshop.
I'm using VirtualBox and an minimal CentOS image (CentOS-7-x86_64-Minimal-1611.iso)
Using VirtialBox I also set up a host-only netork to be shared between the vms that host one MySQL instance each.

More tutorials on the same topic:
- https://mysqlserverteam.com/mysql-innodb-cluster-real-world-cluster-tutorial-for-oel-fedora-rhel-and-centos/
- http://muawia.com/mysql-8-0-innodb-cluster-and-persistent-configurations/
- https://wiki.rdksoft.nl/index.php/Installing_MySQL_InnoDBCluster_on_CentOS_7

Further reading:
- https://dev.mysql.com/doc/refman/8.0/en/mysql-innodb-cluster-userguide.html
- https://dev.mysql.com/doc/refman/8.0/en/mysql-innodb-cluster-sandbox-deployment.html

This workshop was built for MySQL 8 but should work well for MySQL 5.7 as well. Note that MySQL Router 8 and MySQL Shell 8 works for MySQL 5.7 also, I highly recomend using latest versions of MySQL Shell and MySQL Router for any deployments of InnoDB Cluster.


### Prepare your hosts

I will not cover all the steps to start and get the virtual servers up and running.
From now on we have 3 servers up and running and they have a shared network.

Depending on version of OS their might be a need to tweak port openings, a full guide on what port you need to open is available here: https://mysqlserverteam.com/mysql-guide-to-ports/

In this setup I will be lazy and disable iptables and firewalld and treat the 3 servers and their network as protected from the outside.
```
sestatus
sed -i "s/SELINUX=enforcing/SELINUX=permissive/" /etc/sysconfig/selinux
setenforce 0
sestatus

systemctl status firewalld
systemctl disable firewalld
systemctl stop firewalld
systemctl status firewalld
```

##### Hostname mapping

Important: For this tutorial, we assume that the hostname mapping is already done. That is, the name of each host should be resolvable from the other hosts in the cluster.  If not, then please consider configuring the /etc/hosts file before continuing. Hostname mapping is required in order to map a valid hostname to an IP.

Create a /etc/host file with something like:
```
192.168.57.3 idc-1
192.168.57.4 idc-2
192.168.57.5 idc-3
```

And change /etc/hostname to correct entry for each server.
And also run: hostnamectl set-hostname <idc-1>


### Install MySQL
Install and start MySQL on all 3 servers, use latest version (8.0.12).
You can do this manually by using our tar packages or the repository on your OS.
Installing MySQL is explained here: https://dev.mysql.com/doc/refman/8.0/en/installing.html
I will do a manual installation of MySQL bellow.

##### MySQL configuration file
```
[mysqld] 
server-id=3310
datadir=/home/ted/mysqldata
socket=/home/ted/mysqldata/my.sock 
pid-file=/home/ted/mysqldata/my.pid 
log_bin=binlog
default_authentication_plugin=mysql_native_password
```
I have opted to not use the new authentication method since many third party connectors have no support for this yet (Like the native python connector in my test program).

##### Install and start MySQL daemon
```
tar xf mysql-8.0.12-linux-glibc2.12-x86_64.tar.xz
ln -s /home/ted/mysql-8.0.12-linux-glibc2.12-x86_64 mysqlsrc
rm -fr mysql-8.0.12-linux-glibc2.12-x86_64.tar.xz
mkdir /home/ted/mysqldata
/home/ted/mysqlsrc/bin/mysqld --initialize-insecure --datadir=/home/ted/mysqldata --user=ted --basedir=/home/ted/mysqlsrc
/home/ted/mysqlsrc/bin/mysqld_safe --defaults-file=/home/ted/my.cnf --ledir=/home/ted/mysqlsrc/bin &
```
(you need to start the MySQL daemon (mysqld) via mysqld_safe or a service for remote restarts via shell to work)


### Configure admin user for InnoDB Cluster
```
./mysqlsrc/bin/mysql -uroot -S mysqldata/my.sock -e "SET SQL_LOG_BIN=0; CREATE USER 'idcAdmin'@'%' IDENTIFIED BY 'idcAdmin'; GRANT ALL ON *.* TO 'idcAdmin'@'%' WITH GRANT OPTION";
```
Make sure you have no executed GTID's before we start configuring the cluster.
```
./mysqlsrc/bin/mysql -uroot -S mysqldata/my.sock -e "select @@hostname, @@global.gtid_executed"
```
If you have unwanted GTID's recored run "RESET MASTER" to make sure the MySQL instance is clean before joining the cluster.


### Create InnoDB Cluster

##### Check state of MySQL instances
Install MySQL Shell on your prefered server for configuring IDc, does not have to be one of the production servers running MySQL instances.
```
./mysql-shell-8.0.12-linux-glibc2.12-x86-64bit/bin/mysqlsh
```

Check that the instances are a good candidates for joing the cluster:
(Run commands below for all three instances)
```
dba.checkInstanceConfiguration('idcAdmin@192.168.57.3:3306',{password:'idcAdmin'});
```
If check instance spots any issues, solve these by running:
```
dba.configureInstance('idcAdmin@192.168.57.3:3306',{password:'idcAdmin'});
```

Configuration options by configureInstance ("SET PERSIST") can be found in file: mysqldata/mysqld-auto.cnf
You can also view these changes in MySQL by running:
```
./mysqlsrc/bin/mysql -uroot -S mysqldata/my.sock -e "select * from performance_schema.persisted_variables;
```

To see all variables and their source run: SELECT * FROM performance_schema.variables_info WHERE variable_source != 'COMPILED';

##### Create Cluster
Start shell and run:
```
\connect idcAdmin@192.168.57.3:3306
cluster=dba.createCluster("mycluster");
cluster.status();
cluster.addInstance("idcAdmin@192.168.57.4:3306",{password:'idcAdmin'});
cluster.addInstance("idcAdmin@192.168.57.5:3306",{password:'idcAdmin'});
cluster.status();
```

##### Get status of cluster
Connect IDc to a specific MySQL instance using shell:
```
mysqlsh -uidcAdmin -pidcAdmin -h192.168.57.3 -P3306
```
And run:
```
cluster = dba.getCluster();
cluster.status();
```

From performance_schema:
```
SELECT * FROM performance_schema.replication_group_members\G
```

More momitoring data around GR that can be populated in sys schema: https://gist.github.com/lefred/77ddbde301c72535381ae7af9f968322

### MySQL Router

#### Configure and start Router (running on application server)
Bootstrap router from remote host (will pick up all configuration from remote IDc node)
```
./mysql-router-8.0.12-linux-glibc2.12-x86-64bit/bin/mysqlrouter --bootstrap idcAdmin:idcAdmin@192.168.57.3:3306 -d myrouter
```
Command above will create new folder myrouter with configuration and start script.
Configuration file is: myrouter/mysqlrouter.conf
Start Router by running: ./myrouter/start.sh
The router log file is under: myrouter/log/mysqlrouter.log

##### Connect to MySQL group 'via' Router
```
./mysql-8.0.12-linux-glibc2.12-x86_64/bin/mysql -uidcAdmin -pidcAdmin -P6446 -h127.0.0.1
```
Once connected run: SELECT @@PORT, @@HOSTNAME;

### Test failover

Connect to IDc via router:
```
./mysql-8.0.12-linux-glibc2.12-x86_64/bin/mysql -uidcAdmin -pidcAdmin -P6446 -h127.0.0.1
```
And loook at:
SELECT @@PORT, @@HOSTNAME;

Connect shell and look at status, see section "Get status of cluster" above.

Log into primary node and kill mysql: pkill mysql

##### Recover failed node
Start mysql: 
/home/ted/mysqlsrc/bin/mysqld_safe --defaults-file=/home/ted/my.cnf --ledir=/home/ted/mysqlsrc/bin &

Look at state of your cluster, see section "Get status of cluster" above.


##### Test failover using python application.

There is a small python [script](https://gist.github.com/wwwted/6f8d3cfa93a150b112d07895bf5a8722) than can be used to test what happens at failover, the script need the test database to be created before we can start it, connect to the R/W port of router:
```
mysql -uroot -proot -P6446 -h127.0.0.1
``` 
once connected run:
```
create database test;
```

Try to start the python script in a new window/prompt, it will continue to run forever (you can stop it via Ctrl-C):
```
python ./failover-demo.py 6446
```
If you get an error like "Authentication plugin 'caching_sha2_password' is not supported", see Note 1) below on how to fix this.

Output from the failover script should be:
```
3-vm-node-setup$ python ./failover-demo.py 6446
Starting to insert data into MySQL on port: 6446
inside  connect()
Hostname:idc-2 : 3306 ;  John:6 Doe
Hostname:idc-2 : 3306 ;  John:7 Doe
Hostname:idc-2 : 3306 ;  John:8 Doe
Hostname:idc-2 : 3306 ;  John:9 Doe
Hostname:idc-2 : 3306 ;  John:7 Doe
Hostname:idc-2 : 3306 ;  John:8 Doe
Hostname:idc-2 : 3306 ;  John:9 Doe
Hostname:idc-2 : 3306 ;  John:11 Doe
Hostname:idc-2 : 3306 ;  John:8 Doe
Hostname:idc-2 : 3306 ;  John:9 Doe
Hostname:idc-2 : 3306 ;  John:11 Doe
Hostname:idc-2 : 3306 ;  John:12 Doe
```
The script inserts one new employee every iteration and selects the last 5 employees at each iteration. The output also includes the variables (@@HOSTNAME and @@PORT) so we can see the instance we are connected to.

Once you have the python script up and running (or if this does not work, use normal MySQL Client to mimic a real aplication connected to your database) we will now kill the Primary instance of our InnoDB Cluster.

In the output above we can see that idc-2 is our current primary instance.

Log into server with primary instance and kill the mysql processes:
```
bash$ pkill mysql
``` 
You should see a small hickup in the output from the python application then the re-connect should have be triggered and the application should continue to work and output it's normal rows.

##### Recover old primary instance
Steps for recovering a stopped/failed/missing instance are easy, log into server with "missing" instance and start it.
```
/home/ted/mysqlsrc/bin/mysqld_safe --defaults-file=/home/ted/my.cnf --ledir=/home/ted/mysqlsrc/bin &
```
Verify that old primary is now part of cluster again by looking at cluster.status() or data in table performance_schema.replication_group_members.

### Note 1) Problems running script on MySQL due to new authentication plugin (only in MySQL 8)
If you get an error like "Authentication plugin 'caching_sha2_password' is not supported" this means you have python connecter that does not support the new authentication plugn in MySQL 8, no worries, this is true for many 3rd party connectors at the moment and can be solved by configuring MySQL to use old password auth plugin and change plugin for user 'root'.

Run commands below to start using old authentication plugin and set this as plugin for existing 'root' account. It should be enough to set the authentication method for the 'root' account but it looks like the python connector is also looking at MySQL setting for parameter `default_authentication_plugin` and aborts with error message above if this is set to "caching_sha2_password".

Let's first update the configuration and add the line:
```
default_authentication_plugin=mysql_native_password
```
to all instances (the configuration are located at ~$HOME/mysql-sandboxes/$PORT/my.cnf. Make sure you update all 3 nodes (in folders 3310, 3320 and 3330).

Once you have added this line the the configuraton of all instances start the mysql shell
```
mysqlsh
```
and restart the MySQL instances one at a time by running:
```
mysqlsh> dba.stopSandboxInstance(3310);
mysqlsh> dba.startSandboxInstance(3310);
```
Password of all MySQL instances is 'root', this is needed to stop the MySQL instance.

Look at status of your cluster after each node restart, what is happening with the Primary/RW Role?
```
mysqlsh> \c 'root'@127.0.0.1:3320
mysqlsh> cluster = dba.getCluster();
mysqlsh> cluster.status();
```
You need to connect to a running MySQL instance between restarts to see status of the cluster.

Next step is to update our 'root' user to use old plugin, start the mysql client:
```
mysql -uroot -proot -P6446 -h127.0.0.1
```
and then update both 'root' accounts:
```
mysql> ALTER USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY 'root';
mysql> ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'root';
```

If you still have problems running the python script, start the MySQL client via router like:
```
mysql -uroot -proot -P6446 -h127.0.0.1
```
and look at output from commands below, they should look like:
```
mysql> show global variables like 'default_authentication_plugin';
+-------------------------------+-----------------------+
| Variable_name                 | Value                 |
+-------------------------------+-----------------------+
| default_authentication_plugin | mysql_native_password |
+-------------------------------+-----------------------+

mysql> select user,host,plugin from mysql.user where user='root';
+------+-----------+-----------------------+
| user | host      | plugin                |
+------+-----------+-----------------------+
| root | %         | mysql_native_password |
| root | localhost | mysql_native_password |
+------+-----------+-----------------------+
```
