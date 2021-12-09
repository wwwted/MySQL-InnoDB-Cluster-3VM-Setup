**[Back to MySQL HOWTO's](https://github.com/wwwted/MySQL-HOWTOs)**

# MySQL InnoDB Cluster 3VM Setup
![](./img/Mysql_idc.jpg)

In this exercise we will build and test a InnoDB Cluster on 3 servers, virtual or real it's your choice.

You can use any technology you like, I use VirtualBox in this workshop.
I'm using VirtualBox and an minimal CentOS image (CentOS-7-x86_64-Minimal-1611.iso)
Using VirtualBox I also set up a host-only netork to be shared between the vms that host one MySQL instance each.

More tutorials on the same topic:
- https://mysqlserverteam.com/mysql-innodb-cluster-real-world-cluster-tutorial-for-oel-fedora-rhel-and-centos/
- http://muawia.com/mysql-8-0-innodb-cluster-and-persistent-configurations/
- https://wiki.rdksoft.nl/index.php/Installing_MySQL_InnoDBCluster_on_CentOS_7

Further reading:
- https://dev.mysql.com/doc/refman/8.0/en/mysql-innodb-cluster-userguide.html
- https://dev.mysql.com/doc/refman/8.0/en/mysql-innodb-cluster-sandbox-deployment.html

This workshop was built for MySQL 8.0, I highly recomend using latest versions of MySQL Shell and MySQL Router for any deployments of InnoDB Cluster.


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
Install and start MySQL on all 3 servers, use latest version (8.0.20).
You can do this manually by using our tar packages or the repository on your OS.
Installing MySQL is explained here: https://dev.mysql.com/doc/refman/8.0/en/installing.html
I will do a manual installation of MySQL below.

##### MySQL configuration file
```
[mysqld] 
server-id=3310
datadir=/home/ted/mysqldata
pid-file=/home/ted/mysqldata/my.pid 
log_bin=binlog
default_authentication_plugin=mysql_native_password
```
I have opted to not use the new authentication method since many third party connectors have no support for this yet (Like the native python connector in my test program).

##### Install and start MySQL daemon
```
tar xf mysql-8.0.15-linux-glibc2.12-x86_64.tar.xz
ln -s /home/ted/mysql-8.0.12-linux-glibc2.12-x86_64 mysqlsrc
rm -fr mysql-8.0.15-linux-glibc2.12-x86_64.tar.xz
mkdir /home/ted/mysqldata
/home/ted/mysqlsrc/bin/mysqld --initialize-insecure --datadir=/home/ted/mysqldata --user=ted --basedir=/home/ted/mysqlsrc
/home/ted/mysqlsrc/bin/mysqld_safe --defaults-file=/home/ted/my.cnf --ledir=/home/ted/mysqlsrc/bin &
```
(you need to start the MySQL daemon (mysqld) via mysqld_safe or a service for remote restarts via shell to work)


### Configure admin user for InnoDB Cluster
```
./mysqlsrc/bin/mysql -uroot -e "SET SQL_LOG_BIN=0; CREATE USER 'idcAdmin'@'%' IDENTIFIED BY 'idcAdmin'; GRANT ALL ON *.* TO 'idcAdmin'@'%' WITH GRANT OPTION";
```
Make sure you have no executed GTID's before we start configuring the cluster.
```
./mysqlsrc/bin/mysql -uroot -e "select @@hostname, @@global.gtid_executed"
```
If you have unwanted GTID's recored run "RESET MASTER" to make sure the MySQL instance is clean before joining the cluster.
Remember that "RESET MASTER" will only "clean" the state of replication, any real changes done in database (like added users or changed passwords) are still persisted and need to be handled manually.

### Create InnoDB Cluster

##### Check state of MySQL instances
Install MySQL Shell on your prefered server for configuring IDc, does not have to be one of the production servers running MySQL instances.
```
./mysql-shell-8.0.15-linux-glibc2.12-x86-64bit/bin/mysqlsh
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
if you want to automate/script and not use interactive options add options:
```
dba.configureInstance('idcAdmin@192.168.57.3:3306',{password:'idcAdmin',interactive:false,restart:true});
```
Configuration options added by configureInstance ("SET PERSIST") can be found in file: mysqldata/mysqld-auto.cnf
You can also view these changes in MySQL by running:
```
./mysqlsrc/bin/mysql -uroot -e "select * from performance_schema.persisted_variables"
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

##### Dedicated Network for GR communication
We recomend that you use a 10 Gigabit network for InnoDB Cluster.
If you want, you can define a dedicated network for the group replication traffic, this is done by specifying options localAddress and groupSeeds when creating the cluster and adding nodes like:
```
cluster=dba.createCluster("mycluster",{localAddress:'10.0.2.6:33061',groupSeeds:'10.0.2.6:33061,10.0.2.7:33061,10.0.2.8:33061'});
cluster.addInstance('idcAdmin@192.168.57.4:3306',{localAddress:'10.0.2.7:33061',groupSeeds:'10.0.2.6:33061,10.0.2.7:33061,10.0.2.8:33061'});
cluster.addInstance('idcAdmin@192.168.57.5:3306',{localAddress:'10.0.2.8:33061',groupSeeds:'10.0.2.6:33061,10.0.2.7:33061,10.0.2.8:33061'});
```
In above example I created one more network (10.0.2.0/24) for my virtual machines and used this network for group replication traffic only.

##### Configuration recommendations
In general we recommend to use default settings. That said there are circumstances where you might want to make some custom settings.

For most cases I prefer to have bellow settings for InnoDB cluster:
```
group_replication_autorejoin_tries=20
group_replication_member_expel_timeout=5
group_replication_exit_state_action=OFFLINE_MODE
group_replication_consistency=BEFORE_ON_PRIMARY_FAILOVER
```

If you want to configure this when creating your cluster and adding nodes use options bellow:
```
{exitStateAction:'OFFLINE_MODE',autoRejoinTries:'20',consistency:'BEFORE_ON_PRIMARY_FAILOVER'}
```
ExitStateAction "OFFLINE_MODE" was added in 8.0.18. If you are running earlier versions of MySQL, use the default ExitStateActions setting if all access to cluser is done via MySQL Router. If you are accessing data nodes directly consider using "ABORT_SERVER" to avoid reading data from nodes that are expelled from the group.

Some settings might depend on your application workload like support for large transactions, then you might want to tune:
```
group_replication_transaction_size_limit (default ~143MB)
group_replication_member_expel_timeout (expelTimeout)
```
Edit: Above is not needed as of 8.0.16, support for large transactions was added into MySQL 8.0.16, more detals [here](https://mysqlserverteam.com/mysql-innodb-cluster-whats-new-in-the-8-0-16-release/).

Read consistency can be configured on global or session level, for more information on how this works I recommend reading this [blog](https://mysqlhighavailability.com/group-replication-consistent-reads/) by Nuno Carvalho.

##### Get status of cluster
Connect IDc to a specific MySQL instance using shell:
```
mysqlsh -uidcAdmin -pidcAdmin -h192.168.57.3 -P3306
```
And run:
```
cluster = dba.getCluster();
cluster.status();
cluster.options();
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
mysqlrouter --bootstrap idcAdmin:idcAdmin@192.168.57.3:3306 --conf-use-gr-notifications --directory myrouter
```
Command above will create new folder myrouter with configuration and start script.
Configuration file is:
```
myrouter/mysqlrouter.conf
```
Start Router by running:
```
./myrouter/start.sh
```
The router log file is located under:
```
myrouter/log/mysqlrouter.log
```

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

##### Recover cluster from "status" "NO_QUORUM"
If you kill nodes with '-9' option or pull power cables on physical servers there is a risk that the cluster will loose quorum and you need to manually restore cluster from the surviving node. Loss of qourum will happen when you have only 2 nodes left (in a 3 node setup) in cluster and kill (kill -9) one of the nodes. If you want to read more on loss of quorum and how this is handled in group replication read our [manual](https://dev.mysql.com/doc/refman/8.0/en/group-replication-network-partitioning.html)

Run command below on node (in my case node with IP 192.168.57.4) left in cluster:
```
cluster.forceQuorumUsingPartitionOf("idcAdmin@192.168.57.4:3306");
```
After this you need to start/restart the other nodes to join the cluster again.

### Operating InnoDB Cluster

##### Monitoring InnoDB Cluster
There are many ways to monitor InnoDB Cluster, we have already looked at the state via the cluster.status() command using MySQL Shell and by quering the performance_schema.replication_group_members table using the MySQL Client.

MySQL Enterprise Monitor also have many monitoring and alarm features for InnoDB Cluster so you can track the state of your cluster and get alerts if there are problems. MySQL Enterprise Monitor will also visualize the cluster and show the states of the nodes.

== Performance Schema ==
```
select * from performance_schema.replication_group_members\G
select * from performance_schema.replication_group_member_stats\G
select * from performance_schema.replication_connection_status\G
```
== Configuration ==
```
show global variables like '%group_repl%';
```

== Who is primary ==
```
SELECT * FROM performance_schema.replication_group_members WHERE MEMBER_ROLE='PRIMARY';
show global status like 'group%';
```

== Who has the most GTID applied ==
```
select @@global.gtid_executed;
```
##### Start/Stop cluster
Stopping cluster is done by stopping all the MySQL nodes, log into each MySQL node and run:
```
./mysqlsrc/bin/mysqladmin -uroot -S/tmp/mysql.sock shutdown
```
After all nodes are stopped, start them using:
```
/home/ted/mysqlsrc/bin/mysqld_safe --defaults-file=/home/ted/my.cnf --ledir=/home/ted/mysqlsrc/bin &
```
After all MySQL nodes are started, start mysql shell and connect to one of the nodes:
```
mysqlsh -uidcAdmin -pidcAdmin -h192.168.57.3 -P3306
```
and run:
```
cluster = dba.rebootClusterFromCompleteOutage();
```
You might see a error message saying you are trying to start a cluster from a node that is not the most updated one, in the error message you will then see something like "Please use the most up to date instance: '192.168.57.5:3306'", then you should login to this MySQL node and re-run command above.

##### Upgrade InnoDB Cluster
Upgrading InnoDB Cluster is done by restarting the nodes one by one and upgrading the software.
The procedure is called rolling restart and works like:
- Stop MySQL
- Upgrade software
- Start MySQL

For our installation it's enough to download MySQL 8.0.16 and start the new binary. MySQL 8.0.16 handle the upgrade of meta data in the mysqld process so no need to run mysql_upgrade anymore.
Run below operastions on all nodes, one-by-one, start with secondaries and take primary last:
```
 ./mysqlsrc/bin/mysql -uroot -S/tmp/mysql.sock -e"shutdown"
 /home/ted/mysql-8.0.16-linux-glibc2.12-x86_64/bin/mysqld_safe --defaults-file=/home/ted/my.cnf --ledir=/home/ted/mysql-8.0.16-linux-glibc2.12-x86_64/bin &
```

If you have MySQL 8.0.15 or older version of MySQL you also need to run mysql_upgrade (procedure below for yum and systemctl installations):
- mysql> set persist group_replication_start_on_boot=0;
- systemctl stop mysqld
- yum update mysql-community-server mysql-shell
- systemctl start mysqld
- mysql_upgrade
- mysql> set persist group_replication_start_on_boot=1;
- mysql> restart;


##### Set new PRIMARY or test multi-primary mode
Changing PRIMARY node in the cluster can be done by running:
```
cluster.setPrimaryInstance('192.168.57.5:3306');
```
You can also change between single-primary and multi-primary by running:
```
cluster.switchToMultiPrimaryMode();
cluster.switchToSinglePrimaryMode('192.168.57.4:3306');
```

##### Using MySQL Events
Using MySQL Event Scheduler with InnoDB Cluster need to some extra care. When you create the events (on primary server) the events on the secondaries will be set in state "SLAVESIDE_DISABLED". If everything worked as it should when shifting primiary the events should be enabled on new primary and set to "SLAVESIDE_DISABLED" on old primary, today (8.0.16) this is not done and you need to manually handle this, this is explained in the manuals [here](https://dev.mysql.com/doc/refman/8.0/en/replication-features-invoked.html).

I have created a [script](https://github.com/wwwted/MySQL-InnoDB-Cluster-3VM-Setup/blob/master/tools/event_job.sh) in the tools folder that automates this task. The script is not a solution for all scenarios, it will only make sure that events are only active and primary node, on secondary nodes the event scheduler is disabled.

Lets create some simple table and event to see how this works, log into InnoDB Cluster via router:
```
mysql -uidcAdmin -pidcAdmin -P6446 -h127.0.0.1
```
Create a test table and a event to insert some data:
```
CREATE DATABASE ted;
USE ted;
CREATE table ted.t1 (i int primary key);
CREATE EVENT myevent ON SCHEDULE EVERY 1 MINUTE DO INSERT INTO ted.t1 VALUES(UNIX_TIMESTAMP());
SELECT * FROM INFORMATION_SCHEMA.EVENTS\G
SELECT * FROM ted.t1;
```
After a few minutes you will have some rows in table ted.t1.
Looks at event status on secondarie servers also, should be in state "SLAVESIDE_DISABLED".
Let's change primary node (look at cluster.status() and pick one of the secondaries):
```
cluster.setPrimaryInstance('192.168.57.5:3306');
```
 Now you will see that the new primary still have state "SLAVESIDE_DISABLED" for all events and old primary (now secondary) is still trying to run the event (events are enabled) and you will see error in the MySQL error log like "The MySQL server is running with the --super-read-only option so it cannot execute this statement".

Now it's time to run the [script](https://github.com/wwwted/MySQL-InnoDB-Cluster-3VM-Setup/blob/master/tools/event_job.sh) to solve the problems described above:
```
bash$ event_job.sh
PRIMARY(192.168.57.5:3306): Enable all the events and start event scheduler
SECONDARY(192.168.57.3:3306): Disable the event scheduler
```
As the output shows, the script enable all events and starts the event scheduler on the new primary, next step is to disabled the event scheduler on old primary. It's safe to run the script multiple times, first time it will only disable the event scheduler on secondaries (if there has not been a swithover/failover).

### Note 1) Problems running script on MySQL due to new authentication plugin (only in MySQL 8)
If you get an error like "Authentication plugin 'caching_sha2_password' is not supported" this means you have python connecter that does not support the new authentication plugn in MySQL 8, no worries, this is true for many 3rd party connectors at the moment and can be solved by configuring MySQL to use old password auth plugin and change plugin for user 'root'.

Run commands below to start using old authentication plugin and set this as plugin for existing 'root' account. It should be enough to set the authentication method for the 'root' account but it looks like the python connector is also looking at MySQL setting for parameter `default_authentication_plugin` and aborts with error message above if this is set to "caching_sha2_password".

Let's first update the configuration and add the line:
```
default_authentication_plugin=mysql_native_password
```
to all MySQL instances and restart them.

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
