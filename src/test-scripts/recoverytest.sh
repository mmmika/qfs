#!/bin/sh
#
# $Id$
#
# Created 2014/06/06
# Author: Mike Ovsiannikov
#
# Copyright 2014 Quantcast Corp.
#
# This file is part of Kosmos File System (KFS).
#
# Licensed under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.
#
# Test RS recovery with sparse files by creating sparse file and forcing
# recovery by deleting chunk files and running file verification, and
# using admin tool to force recovery of existing chunks.

ulimit -c unlimited

builddir=`pwd`
toolsdir=${toolsdir-"$builddir"/src/cc/tools}
metadir=${metadir-"$builddir"/src/cc/meta}
chunkdir=${chunkdir-"$builddir"/src/cc/chunk}
devtoolsdir=${devtoolsdir-`dirname "$toolsdir"`/devtools}
qfstestdir=${qfstestdir-"$builddir"/qfstest}
clicfg=${clicfg-"$qfstestdir"/client.prp}
clirootcfg=${clirootcfg-"$qfstestdir"/clientroot.prp}
metaport=${metaport-20200}
metahost=${metahost-127.0.0.1}
maxrecovsize=${maxrecovsize-5242880}
testblocksizes=${testblocksizes-'26214399 26214400 29358894 26214401'}
testtailblocksize=${testtailblocksize-1}
filecreateparams=${filecreateparams-'fs.createParams=1,6,3,1048576,2,15,15'}
csstartport=${csstartport-20400}
csendport=${csendport-`expr $csstartport + 1`}
valgrind_cmd=${valgrind_cmd-''}

start=1
runtest=1
stop=1

while [ $# -gt 0 ]; do
    if [ x"$1" = x'-valgrind' ]; then
        valgrind_cmd='valgrind -v --log-file=valgrind-recovery.log --leak-check=full --leak-resolution=high --show-reachable=yes --track-origins=yes --'
    elif [ x"$1" = x'-start-only' ]; then
        start=1
        runtest=0
        stop=0
    elif [ x"$1" = x'-run-only' ]; then
        start=0
        stop=0
        runtest=1
    elif [ x"$1" = x'-shutdown-only' ]; then
        runtest=0
        start=0
        stop=1
    else
        echo "Usage: $0 [-valgrind] [-start-only] [-run-only] [-shutdown-only]"
        exit 1
    fi
    shift
done

if [ $start -ne 0 ]; then
    cd "$qfstestdir"/meta || exit
    kill -KILL `cat metaserver.pid` 2>/dev/null
    rm -f kfscp/* kfslog/*
    rm -f metaserver-recovery.log
    cp MetaServer.prp MetaServer-recovery.prp || exit
    echo "metaServer.panicOnInvalidChunk=1" >> MetaServer-recovery.prp
    "$metadir"/metaserver -c MetaServer-recovery.prp > metaserver-recovery.log 2>&1 &
    echo $! > metaserver.pid
    cd ../..
    i=$csstartport
    while [ $i -le $csendport ]; do
        cd "$qfstestdir"/chunk/$i || exit
        kill -KILL `cat chunkserver.pid` 2>/dev/null
        rm -f chunkserver-recovery.log
        rm -rf kfschunk*/*
        sed -e 's/^\(chunkServer.diskIo.crashOnError.*\)$/# \1/' \
            ChunkServer.prp > ChunkServer-recovery.prp
        {
            echo "chunkServer.rsReader.maxRecoverChunkSize=$maxrecovsize"
            echo "chunkServer.rsReader.panicOnInvalidChunk=1"
        } >> ChunkServer-recovery.prp
        $valgrind_cmd "$chunkdir"/chunkserver ChunkServer-recovery.prp \
            > chunkserver-recovery.log 2>&1 &
        echo $! > chunkserver.pid
        cd ../../..
        i=`expr $i + 1`
    done
fi

function wait_shutdown_complete()
{
    pid=$0
    maxtry=${1-100}
    k=0
    while kill -0 $pid 2>/dev/null; do
        sleep 1
        k=`expr $k + 1`
        if [ $k -gt $maxtry ]; then
            echo "server $pid shutdown failure" 1>&2
            kill -ABRT $pid
            sleep 3
            kill -KILL $pid 2>/dev/null
            return 1
        fi
    done
    return 0
}

function shutdown()
{
    status=0
    cd "$qfstestdir"/meta || return 1
    pid=`cat metaserver.pid`
    kill -QUIT $pid
    if wait_shutdown_complete $pid; then
        true;
    else
        status 1
    fi
    cd ../..
    i=$csstartport
    while [ $i -le $csendport ]; do
        cd "$qfstestdir"/chunk/$i || return 1
        pid=`cat chunkserver.pid`
        kill -QUIT `cat chunkserver.pid`
        if wait_shutdown_complete $pid; then
            true;
        else
            status 1
        fi
        i=`expr $i + 1`
    done
    return $status
}

if [ $runtest -eq 0 ]; then
    if [ $stop -ne 0 ]; then
        if shutdown; then
            exit 0
        else
            exit 1
        fi
    fi
    exit 0
fi

function verify_file()
{
    filemd5=`"$toolsdir"/qfs \
        -D fs.readFullSparseFileSupport=1 \
        -cfg "$clicfg" \
        -cat "qfs://$metahost:$metaport/user/$usr/testrep.dat" \
        | openssl md5 | awk '{print $NF}'`

    if [ x"$testmd5" = x"$filemd5" ]; then
        return 0
    fi
    echo "read checsum mismath: expected: $testmd5 actual: $filemd5"
    return 1
}

usr=`id -un`
[ -f "$clicfg"     ] || clicfg=/dev/null
[ -f "$clirootcfg" ] || clirootcfg=/dev/null

status=0
"$toolsdir"/qfs \
    -cfg "$clicfg" \
    -mkdir "qfs://$metahost:$metaport/user/$usr" || status=1

for testblocksize in $testblocksizes ; do
    [ $status -eq 0 ] || break

    "$toolsdir"/qfs \
        -cfg "$clicfg" \
        -rm -skipTrash "qfs://$metahost:$metaport/user/$usr/testrep*.dat"

    "$devtoolsdir"/rand-sfmt -g $testtailblocksize 1234 \
        | "$toolsdir"/qfs \
            -cfg "$clicfg" \
            -D "$filecreateparams" \
            -put - "qfs://$metahost:$metaport/user/$usr/testrep1.dat" || {
        status=1
        break;
    }

    "$devtoolsdir"/rand-sfmt -g $testblocksize 1234 \
        | "$toolsdir"/qfs \
            -cfg "$clicfg" \
            -D "$filecreateparams" \
            -put - "qfs://$metahost:$metaport/user/$usr/testrep.dat" || {
        status=1
        break;
    }

    "$toolsdir"/qfsshell \
            -f "$clicfg" -s $metahost -p $metaport -q -- \
            append "/user/$usr/testrep1.dat" "/user/$usr/testrep.dat" || {
        status=1
        break;
    }

    testholesize=`expr 1024 \* 1024 \* 64 \* 6 - $testblocksize`
    testmd5=`{ \
        "$devtoolsdir"/rand-sfmt -g $testblocksize 1234 ;
        dd bs=$testholesize count=1 if=/dev/zero 2>/dev/null ;
        "$devtoolsdir"/rand-sfmt -g $testtailblocksize 1234 ;
    } | openssl md5 | awk '{print $NF}'`

    verify_file || {
        status=1
        break
    }
    fenumout="$qfstestdir/fenum.txt"
    "$toolsdir"/qfsfileenum -s $metahost -p $metaport -c "$clicfg" \
            -f "/user/$usr/testrep.dat" > "$fenumout"
    cat "$fenumout"

    tmpchunk="$qfstestdir/tmpchunk"

    rm -rf "$tmpchunk"
    mkdir "$tmpchunk" || exit

    k=0
    while read stripes; do
        echo "============== $testblocksize = $k == $stripes =================="
        eval `awk '
            BEGIN{ i=0; }
            /^position: /{
                print "chunkid"   i "=" $4  ";";
                print "chunkvers" i "=" $6  ";";
                print "srvhost"   i "=" $10 ";";
                print "srvport"   i "=" $11 ";";
                i++;
            }
        ' "$fenumout"`
        rm -rf "$tmpchunk/$k"
        mkdir "$tmpchunk/$k" || exit
        m=-1
        s=0
        for i in $stripes; do
            if [ $m -lt 0 -a $s -eq 0 ]; then
                m=$i
                s=1
                continue
            fi
            if [ $i -lt 0 ]; then
                i=`expr 0 - $i`
                b=1
            else
                b=0
            fi
            eval srvport='$srvport'$i
            eval chunksuf='$chunkid'$i'.$chunkvers'$i
            chunkf=`echo "$qfstestdir/chunk/$srvport/"*/*".$chunksuf"`
            if [ $b -eq 0 ]; then
                ls -l "$chunkf"
                mv "$chunkf" "$tmpchunk/$k" || exit
            else
                # Restore the original chunk file.
                cfname="`basename "$chunkf"`"
                t=0
                while [ $t -le $k ]; do
                    [ -f "$tmpchunk/$t/$cfname" ] && break
                    t=`expr $t + 1`
                done
                cp "$tmpchunk/$t/$cfname" "$chunkf.orig" || exit
                mv "$chunkf.orig" "$chunkf" || exit
                ls -l "$chunkf"
            fi
        done

        s=0
        for n in $m ; do
            [ $m -lt 0 ] && continue
            [ $s -ne 0 -a $n -eq $m ] && continue
            s=0
            eval srvport='$srvport'$n
            eval srvhost='$srvhost'$n
            eval chunkid='$chunkid'$n
            srvportr=`expr $srvport + 1`
            if [ $srvportr -gt $csendport ]; then
                srvportr=$csstartport
            fi

            echo "forcing recovery: chunk: $chunkid port: $srvportr"
            "$toolsdir"/qfsadmin -s "$metahost" -p "$metaport" -f "$clirootcfg" -a \
                -F "Chunk=$chunkid" \
                -F "Host=$srvhost" \
                -F "Port=$srvportr" \
                -F "Recovery=1" \
                force_replication || exit
        done
        # Wait for chunk recoveries to complete.
        t=0
        while sleep 3; do
            "$toolsdir"/qfsdataverify \
                -s "$metahost" -p "$metaport" -f "$clicfg" -c -d -k \
                    "/user/$usr/testrep.dat" 1>/dev/null 2>/dev/null && break
            t=`expr $t + 1`
            if [ $t -gt 100 ]; then
                status=1
                break
            fi
        done
        [ $status -eq 0 ] || break;
        mv "$fenumout" "$fenumout.prev"
        "$toolsdir"/qfsfileenum -s "$metahost" -p "$metaport" -c "$clicfg" \
            -f "/user/$usr/testrep.dat" > "$fenumout"
        cat "$fenumout"
        sed -e 's/ [0-9]*$//' "$fenumout"      > "$fenumout.np"
        sed -e 's/ [0-9]*$//' "$fenumout.prev" > "$fenumout.prev.np"
        diff -du  "$fenumout.prev.np" "$fenumout.np"
        verify_file || {
            status=1
            break
        }
        echo "============== $testblocksize = $k == $stripes =================="
        k=`expr $k + 1`
    done << EOF
    -1 0 1 5
    6 3 7 8
    0 0 1 2
    5 5 6
    -1 4 5
    -1 10 11
    -1 10 11 12
    -1 -3 -5
    -1 0 1 5
EOF
    [ $status -eq 0 ] || break;
done
# Format:
# <stripe to force recovery> <stripe to delete> <stripe to delete> <stripe to delete>
# negative stripe / chunk numbers except the first column means restore the
# "original" chunk.

if [ $stop -eq 0 ] || shutdown; then
    if [ $status -eq 0 ]; then
        echo "Passed all tests"
        exit 0
    fi
fi
exit 1
