#!/bin/bash -ex

[ -z "$SUDO" ] && SUDO=sudo
[ -x ../src/ceph-daemon ] && CEPH_DAEMON=../src/ceph-daemon
[ -x ./ceph-daemon ] && CEPH_DAEMON=.ceph-daemon
which ceph-daemon && CEPH_DAEMON=$(which ceph-daemon)

FSID='00000000-0000-0000-0000-0000deadbeef'
IMAGE='ceph/daemon-base:latest-master'

# clean up previous run(s)?
$SUDO $CEPH_DAEMON rm-cluster --fsid $FSID --force

TMPDIR=`mktemp -d -p .`
trap "rm -rf $TMPDIR" TERM HUP INT

function expect_false()
{
        set -x
        if "$@"; then return 1; else return 0; fi
}

## version + --image
$SUDO $CEPH_DAEMON --image ceph/daemon-base:latest-nautilus version \
    | grep 'ceph version 14'
$SUDO $CEPH_DAEMON --image ceph/daemon-base:latest-mimic version \
    | grep 'ceph version 13'
$SUDO $CEPH_DAEMON --image $IMAGE version | grep 'ceph version'

# try force docker; this won't work if docker isn't installed
which docker && ( $SUDO $CEPH_DAEMON --docker version | grep 'ceph version' )

## bootstrap
ORIG_CONFIG=`mktemp -p $TMPDIR`
CONFIG=`mktemp -p $TMPDIR`
KEYRING=`mktemp -p $TMPDIR`
IP=127.0.0.1
cat <<EOF > $ORIG_CONFIG
[global]
log to file = true
EOF
$SUDO $CEPH_DAEMON --image $IMAGE bootstrap \
      --mon-id a \
      --mgr-id x \
      --mon-ip $IP \
      --fsid $FSID \
      --config $ORIG_CONFIG \
      --output-config $CONFIG \
      --output-keyring $KEYRING \
      --skip-ssh
test -e $CONFIG
test -e $KEYRING
rm -f $ORIG_CONFIG

$SUDO test -e /var/log/ceph/$FSID/ceph-mon.a.log
$SUDO test -e /var/log/ceph/$FSID/ceph-mgr.x.log

for u in ceph.target \
	     ceph-$FSID.target \
	     ceph-$FSID@mon.a \
	     ceph-$FSID@mgr.x; do
    systemctl is-enabled $u
    systemctl is-active $u
done
systemctl | grep system-ceph | grep -q .slice  # naming is escaped and annoying

## ls
$SUDO $CEPH_DAEMON ls | jq '.[]' | jq 'select(.name == "mon.a").fsid' \
    | grep $FSID
$SUDO $CEPH_DAEMON ls | jq '.[]' | jq 'select(.name == "mgr.x").fsid' \
    | grep $FSID

## exec (and ceph -s works)
$SUDO $CEPH_DAEMON exec --fsid $FSID -n mon.a -- \
      ceph -k /var/lib/ceph/mon/ceph-a/keyring -n mon. -s | grep $FSID

## deploy
# add mon.b
$SUDO $CEPH_DAEMON --image $IMAGE deploy --name mon.b \
      --fsid $FSID \
      --mon-ip $IP:3301 \
      --keyring /var/lib/ceph/$FSID/mon.a/keyring \
      --config $CONFIG
for u in ceph-$FSID@mon.b; do
    systemctl is-enabled $u
    systemctl is-active $u
done

# add mgr.y
$SUDO $CEPH_DAEMON exec --fsid $FSID -n mon.a -- \
      ceph -k /var/lib/ceph/mon/ceph-a/keyring -n mon. \
      auth get-or-create mgr.y \
      mon 'allow profile mgr' \
      osd 'allow *' \
      mds 'allow *' > $TMPDIR/keyring.mgr.y
$SUDO $CEPH_DAEMON --image $IMAGE deploy --name mgr.y \
      --fsid $FSID \
      --keyring $TMPDIR/keyring.mgr.y \
      --config $CONFIG
for u in ceph-$FSID@mgr.y; do
    systemctl is-enabled $u
    systemctl is-active $u
done
for f in `seq 1 30`; do
    if $SUDO $CEPH_DAEMON exec --fsid $FSID -n mon.a -- \
	  ceph -k /var/lib/ceph/mon/ceph-a/keyring -n mon. -s -f json-pretty \
	| jq '.mgrmap.num_standbys' | grep -q 1 ; then break; fi
    sleep 1
done
$SUDO $CEPH_DAEMON exec --fsid $FSID -n mon.a -- \
      ceph -k /var/lib/ceph/mon/ceph-a/keyring -n mon. -s -f json-pretty \
    | jq '.mgrmap.num_standbys' | grep -q 1

## run
## shell
## enter
## unit
## adopt

## ceph-volume
$SUDO $CEPH_DAEMON --image $IMAGE ceph-volume --fsid $FSID -- inventory --format=json \
      | jq '.[]'

## rm-daemon
# mon and osd require --force
expect_false $SUDO $CEPH_DAEMON rm-daemon --fsid $FSID --name mon.a
# mgr does not
$SUDO $CEPH_DAEMON rm-daemon --fsid $FSID --name mgr.x

## rm-cluster
expect_false $SUDO $CEPH_DAEMON rm-cluster --fsid $FSID
$SUDO $CEPH_DAEMON rm-cluster --fsid $FSID --force

rm -rf $TMPDIR
echo PASS
