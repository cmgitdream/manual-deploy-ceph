#!/bin/bash

function mon_mkfs_from_ceph_conf_single_node()
{ 
	local func=mon_mkfs_from_ceph_conf_single_node
	if [ $# -lt 1 ];then
		echo "$func: <conf>"
		exit
	fi
	conf=$1
	mon_keyring=/tmp/ceph.mon.keyring
	client_keyring=/etc/ceph/ceph.client.admin.keyring
	# mon keyring
	ceph-authtool --create-keyring $mon_keyring --gen-key -n mon. --cap mon 'allow *';
	# client keyring
	ceph-authtool --create-keyring $client_keyring --gen-key -n client.admin \
		--set-uid=0 --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow';
	# add client keyring to mon keyring
	ceph-authtool $mon_keyring --import-keyring $client_keyring
	
	#create monmap
	monmap=/tmp/monmap
	mon_dir=/var/lib/ceph/mon
	fsid=`ceph-conf --lookup fsid -c $conf`
	if [ "$fsid" = ""x ];then
		echo "must specify fsid"
		exit
	fi

	cluster=ceph
	tmp_cluster=`ceph-conf --lookup cluster -c $conf`
	if [ "$tmp_cluster"x != x ];then
		cluster=$tmp_cluster
	fi
	
	declare -a mons
	declare -a mon_datas
	i=0
	cmd="monmaptool --create "
	for mon in `ceph-conf -l mon. -c $conf`
	do
		id=`echo $mon|awk -F "." '{print $2}'`
		#mon_data=$mon_dir/ceph-$id
		ip_port=`ceph-conf -s $mon --lookup "mon addr" -c $conf|head -n 1`
		init_dir=`ceph-conf -s $mon --lookup "mon data" -c $conf|head -n 1`
		dir=`dirname $init_dir`
	 	if [ "$dir"x = x ];then	
			echo "$func: $conf: $mon \"mon data\" NOT specified"
			exit
		fi
		mon_data=$dir/$cluster-$id
		echo "mon_data: $mon_data"
		mons[$i]=$mon
		mon_datas[$i]=$mon_data
		i=$(($i+1))
		rm -rf $mon_data
		mkdir -p $mon_data
		cmd="$cmd --add $id $ip_port"
	done
	cmd="$cmd --fsid $fsid --clobber $monmap"
	eval $cmd
	
	i=0
	# mon mkfs
	for mon in `ceph-conf -l mon. -c $conf`
	do
		id=`echo $mon|awk -F "." '{print $2}'`
		m_data=${mon_datas[$i]}
		i=$(($i+1))
		ceph-mon -c $conf --mkfs -i $id --monmap $monmap --keyring $mon_keyring --mon-data $m_data
	done
}

# make sure mon already running first
function add_osd() {
	local func=add_osd
	if [ $# -lt 3 ];then
		echo "$func: <conf> <host> <osd_data> <osd_journal>"
		return 1
	fi
	local conf=$1
 	local host=$2
	local osd_data=$3
	local osd_journal=$4
	local remote_conf=/etc/ceph/ceph.conf
	echo "$func: check osd_data & journal"
	ssh $host "mkdir -p /etc/ceph $osd_data"
	scp $conf $host:/etc/ceph/
#	ssh $host "
#	echo $osd_data
#	if [ ! -e $osd_data ];then
#		echo \"$osd_data NOT exist\"
#		return 1
#	fi
#	
#	if [ -d $osd_data ] && [ `ls $osd_data|head -n 1`x != \"\"x ];then
#		echo \"$osd_data NOT empty\"
#		return 1
#	fi
#	"
	
	echo "$func: will mkfs"

	uuid=`ssh $host uuidgen`
	echo "uuid: $uuid"
	echo -n "ceph fsid: "
	ceph -c $conf fsid
	id=`ceph -c $conf osd create $uuid` #[{id}]]

	# mkfs on remote host
	ssh $host "ceph-osd -c /etc/ceph/ceph.conf -i $id --osd-data $osd_data --osd-journal $osd_journal --mkfs --mkkey --osd-uuid $uuid"
	if [ $? -ne 0 ];then
	 	echo "mkfs on $host failed"
	fi

	echo "$func: will add auth"
	ssh $host "ceph -c $remote_conf auth add osd.$id osd 'allow *' mon 'allow profile osd' -i $osd_data/keyring"

	echo "$func: will add crush"
	ceph -c $conf osd crush add-bucket $host host
	ceph -c $conf osd crush move $host root=default
	ceph -c $conf osd crush add osd.$id 1.0 host=$host
}

function rm_osd()
{
  	local func=rm_osd
	conf=$1
	id=$2
	ceph -c $conf osd out $id
	ceph -c $conf osd crush remove osd.$id
	ceph -c $conf osd rm $id
	ceph -c $conf auth del osd.$id
}

function deploy_mon()
{
	echo "deploy_mon"
	mon_mkfs_from_ceph_conf_single_node $1
}

function usage()
{
	echo "usage: deploy_mon	<conf>";
	echo "       add_osd 	<conf> <host> <osd_data> <osd_journal>";
	echo "       rm_osd 	<conf> <osd_id>";
}

function run()
{
	if [ $# -lt 1 ];then
		usage
		exit 
	elif [ $1 = deploy_mon ];then
		if [ $# -lt 2 ];then
			usage
			exit
		fi
		echo "$1 $2"
		deploy_mon $2
	elif [ $1 = add_osd ];then
		if [ $# -lt 5 ];then
			usage
			exit
		fi
		add_osd $2 $3 $4 $5
	elif [ $1 = rm_osd ];then
		if [ $# -lt 3 ];then
			usage
			exit
		fi
		rm_osd $2 $3
	else 
		usage
	fi
}

run $*

