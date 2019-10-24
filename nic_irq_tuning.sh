#!/bin/bash
# This is the default setting of networking multiqueue and RPS/XPS/RFS on DC2.
# 1. enable multiqueue if available
# 2. disable RPS/XPS optimization
# 3. disable RFS optimization
# 4. start irqbalance service

# set and check multiqueue
function set_check_multiqueue()
{
    eth=$1
    log_file=$2


    pre_max=`ethtool -l $eth 2>/dev/null | grep -i "combined" | head -n 1 | awk '{print $2}'`
    cur_max=`ethtool -l $eth 2>/dev/null | grep -i "combined" | tail -n 1 | awk '{print $2}'`
    # if ethtool not work. we have to deal with this situation.
    [[ ! "$pre_max" =~ ^[0-9]+$ ]] || [[ ! "$cur_max" =~ ^[0-9]+$ ]] && return

    queue_num=$(ethtool -l $eth | grep -iA5 'pre-set' | grep -i combined | awk {'print $2'})
    if [ $queue_num -gt 1 ]; then
        # set multiqueue
        ethtool -L $eth combined $queue_num
        # check multiqueue setting
        cur_q_num=$(ethtool -l $eth | grep -iA5 current | grep -i combined | awk {'print $2'})
        if [ "X$queue_num" != "X$cur_q_num" ]; then
            echo "Failed to set $eth queue size to $queue_num" >> $log_file
            echo "after setting, pre-set queue num: $queue_num , current: $cur_q_num" >> $log_file
            return 1
        else
            echo "OK. set $eth queue size to $queue_num" >> $log_file
        fi
    else
        echo "only support $queue_num queue; no need to enable multiqueue on $eth" >> $log_file
    fi
}

# calculate the cpuset for RPS/XPS cpus
function cal_cpuset()
{
    cpu_nums=$(grep -c processor /proc/cpuinfo)
    if [ $cpu_nums -gt 32 ]; then
        mask_tail=""
        mask_low32="ffffffff"
        idx=$((cpu_nums/32))
        cpu_reset=$((cpu_nums-idx*32))

        if [ $cpu_reset -eq 0 ]; then
            mask=$mask_low32
            for((i=2;i<=idx;i++))
            do
                mask="$mask,$mask_low32"
            done
        else
            for ((i=1;i<=idx;i++))
            do
                mask_tail="$mask_tail,$mask_low32"
            done
            mask_head_num=$((2**cpu_reset-1))
            mask=`printf "%x%s" $mask_head_num $mask_tail`
        fi
    else
        mask_num=$((2**cpu_nums-1))
        mask=`printf "%x" $mask_num`
    fi
    echo $mask
}

# disable RPS/XPS feature
function set_rps_xps()
{
    eth=$1
    cpuset=$2
    for rps_file in $(ls /sys/class/net/${eth}/queues/rx-*/rps_cpus)
    do
        echo $cpuset > $rps_file
    done
    for xps_file in $(ls /sys/class/net/${eth}/queues/tx-*/xps_cpus)
    do
        echo $cpuset > $xps_file
    done
}

# check RPS/XPS cpus setting
function check_rps_xps()
{
    eth=$1
    exp_cpus=$2
    log_file=$3
    ((exp_cpus=16#$exp_cpus))
    ret=0
    for rps_file in $(ls /sys/class/net/${eth}/queues/rx-*/rps_cpus)
    do
        ((cur_cpus=16#$(cat $rps_file | tr -d ",")))
        if [ "X$exp_cpus" != "X$cur_cpus" ]; then
            echo "Failed to check RPS setting on $rps_file" >> $log_file
            echo "expect: $exp_cpus, current: $cur_cpus" >> $log_file
            ret=1
        else
            echo "OK. check RPS setting on $rps_file" >> $log_file
        fi
    done
    for xps_file in $(ls /sys/class/net/${eth}/queues/tx-*/xps_cpus)
    do
        ((cur_cpus=16#$(cat $xps_file | tr -d ",")))
        if [ "X$exp_cpus" != "X$cur_cpus" ]; then
            echo "Failed to check XPS setting on $xps_file" >> $log_file
            echo "expect: $exp_cpus, current: $cur_cpus" >> $log_file
            ret=1
        else
            echo "OK. check XPS setting on $xps_file" >> $log_file
        fi
    done
    return $ret
}

# enable RFS feature
function set_check_rfs()
{
    log_file=$1
    total_queues=0
    rps_flow_cnt_num=4096
    rps_flow_entries_file="/proc/sys/net/core/rps_sock_flow_entries"
    ret=0
    for j in $(ls -d /sys/class/net/eth*)
    do
        eth=$(basename $j)
        queues=$(ls -ld /sys/class/net/$eth/queues/rx-* | wc -l)
        total_queues=$(($total_queues + $queues))
        for k in $(ls /sys/class/net/$eth/queues/rx-*/rps_flow_cnt)
        do
            echo $rps_flow_cnt_num > $k
            if [ "X$rps_flow_cnt_num" != "X$(cat $k)" ]; then
                echo "Failed to set $rps_flow_cnt_num to $k" >> $log_file
                ret=1
            else
                echo "OK. set $rps_flow_cnt_num to $k" >> $log_file
            fi
        done
    done
    total_flow_entries=$(($rps_flow_cnt_num * $total_queues))
    echo $total_flow_entries > $rps_flow_entries_file
    if [ "X$total_flow_entries" != "X$(cat $rps_flow_entries_file)" ]; then
        echo "Failed to set $total_flow_entries to $rps_flow_entries_file" >> $log_file
        ret=1
    else
        echo "OK. set $total_flow_entries to $rps_flow_entries_file" >> $log_file
    fi
    return $ret
}

# start irqbalance service
function start_irqblance()
{
    log_file=$1
    ret=0
    cpu_num=$(grep -c processor /proc/cpuinfo)
    if [ $cpu_num -lt 2 ]; then
        echo "No need to start irqbalance" >> $log_file
        echo "found $cpu_num processor in /proc/cpuinfo" >> $log_file
        return $ret
    fi
    if [ "X" = "X$(ps -ef | grep irqbalance | grep -v grep)" ]; then
        ret=`systemctl start irqbalance 2>&1`
        sleep 1
        ret=`systemctl status irqbalance &> /dev/null`
        if [ $? -ne 0 ]; then
            service irqbalance start
            if [ $? -ne 0 ]; then
                echo "Failed to start irqbalance" >> $log_file
                ret=1
            fi
        else
            echo "OK. irqbalance started." >> $log_file
        fi
    else
        echo "irqbalance is running, no need to start it." >> $log_file
    fi
    return $ret
}

# stop irqbalance service
function stop_irqblance()
{
    log_file=$1
    ret=0

    if [ "X" != "X$(ps -ef | grep irqbalance | grep -v grep)" ]; then
        systemd=`which systemctl`
        if [ $? -eq 0 ];then
            systemctl stop irqbalance
        else
            service irqbalance stop
        fi
        if [ $? -ne 0 ]; then
            echo "Failed to stop irqbalance" >> $log_file
            ret=1
        fi

    else
       echo "OK. irqbalance stoped." >> $log_file
    fi
    return $ret
}


# return 0: Current instance is a kvm vm
# return 1: Current instance is not a kvm vm
function is_kvm_vm()
{
    local ret1
    local ret2

    lscpu 2>/dev/null | grep -i kvm >/dev/null 2>&1
    ret1=$?

    cat /sys/devices/system/clocksource/clocksource0/available_clocksource 2>/dev/null  | grep -i kvm >/dev/null 2>&1
    ret2=$?

    if [ "$ret1" == "0" -o "$ret2" == "0" ];then
        return 0
    else
        return 1
    fi
}

function get_highest_mask()
{
    cpu_nums=$1
    if [ $cpu_nums -gt 32 ]; then
        mask_tail=""
        mask_low32="00000000"
        idx=$((cpu_nums/32))
        cpu_reset=$((cpu_nums-idx*32))

        if [ $cpu_reset -eq 0 ]; then
            mask="80000000"
            for((i=2;i<=idx;i++))
            do
                mask="$mask,$mask_low32"
            done
        else
            for ((i=1;i<=idx;i++))
            do
                mask_tail="$mask_tail,$mask_low32"
            done
            mask_head_num=$((1<<(cpu_reset-1)))
            mask=`printf "%x%s" $mask_head_num $mask_tail`
        fi

    else
        mask_num=$((1<<(cpu_nums-1)))
        mask=`printf "%x" $mask_num`
    fi
    echo $mask
}

function get_smp_affinity_mask()
{
    local cpuNums=$1

    if [ $cpuNums -gt $cpuCount ]; then
        cpuNums=$(((cpuNums - 1) % cpuCount + 1))
    fi

    get_highest_mask $cpuNums
}

function input_irq_bind()
{
    log_file=$1
    netQueueCount=`cat /proc/interrupts  | grep -i ".*virtio.*input.*" | wc -l`
    irqSet=`cat /proc/interrupts  | grep -i ".*virtio.*input.*" | awk -F ':' '{print $1}'`
    i=0
    for irq in $irqSet
    do
        cpunum=$((i%cpuCount+1))
        mask=`get_smp_affinity_mask $cpunum`
        echo "irq affinity input queue setting:echo $mask > /proc/irq/$irq/smp_affinity" >> $log_file
        echo $mask > /proc/irq/$irq/smp_affinity
        echo "[input]bind irq $irq with mask 0x$mask affinity"  >> $log_file
        ((i++))
    done
}

function output_irq_bind()
{
    log_file=$1
    netQueueCount=`cat /proc/interrupts  | grep -i ".*virtio.*input.*" | wc -l`
    irqSet=`cat /proc/interrupts  | grep -i ".*virtio.*output.*" | awk -F ':' '{print $1}'`
    i=0
    for irq in $irqSet
    do
        cpunum=$((i%cpuCount+1))
        mask=`get_smp_affinity_mask $cpunum`
        echo "irq affinity output queue setting:echo $mask > /proc/irq/$irq/smp_affinity" >> $log_file
        echo $mask > /proc/irq/$irq/smp_affinity
        echo "[output]bind irq $irq with mask 0x$mask affinity" >> $log_file
        ((i++))
    done
}

smartnic_bind()
{
    log_file=$1
    return
}

function set_vm_net_affinity()
{
    log_file=$1
    ps ax | grep -v grep | grep -q irqbalance && killall irqbalance 2>/dev/null
    cat /proc/interrupts  | grep "LiquidIO.*rxtx" &>/dev/null
    if [ $? -eq 0 ]; then # smartnic
        smartnic_bind $log_file
    else
        input_irq_bind $log_file
        output_irq_bind $log_file
    fi
}


function stop_rps()
{
    eth=$1

    for i in ${eth}
    do
        cur_eth=$(basename $i)
        pre_max=`ethtool -l $cur_eth 2>/dev/null | grep -i "combined" | head -n 1 | awk '{print $2}'`
        cur_max=`ethtool -l $cur_eth 2>/dev/null | grep -i "combined" | tail -n 1 | awk '{print $2}'`
        # if ethtool not work. we have to deal with this situation.
        [[ ! "$pre_max" =~ ^[0-9]+$ ]] || [[ ! "$cur_max" =~ ^[0-9]+$ ]] && return

        queue_num=$(ethtool -l $cur_eth | grep -iA5 'pre-set' | grep -i combined | awk {'print $2'})
        if [ $queue_num -gt 1 ]; then
            set_rps_xps "$cur_eth" 0

            rps_flow_cnt_num=4096

            for k in $(ls /sys/class/net/$cur_eth/queues/rx-*/rps_flow_cnt)
            do
                echo 0 > $k
            done
        fi
    done


    rps_flow_entries_file="/proc/sys/net/core/rps_sock_flow_entries"
    echo 0 > ${rps_flow_entries_file}
}

function set_irq_smpaffinity()
{
    log_file=$1
    cpuCount=`cat /proc/cpuinfo |grep processor |wc -l`
    if [ $cpuCount -eq 0 ] ;then
        echo "machine cpu count get error!"  >> $log_file
        exit 0
    elif [ $cpuCount -eq 1 ]; then
        echo "machine only have one cpu, needn't set affinity for net interrupt"  >> $log_file
        exit 0
    fi

    is_kvm_vm
    if [ $? -ne 0 ];then
        #set_bm_net_affinity
        echo "not a kvm vm, so not set the irq affinity"  >> $log_file
    else
        set_vm_net_affinity $log_file
    fi
}

# net setting main logic
function main()
{
    dc2_mq_rps_rfs_log=/var/log/dc2_mq_network_rps_rfs.log
    ret_value=0
    rps_xps_cpus=$(cal_cpuset)
    echo "running $0" > $dc2_mq_rps_rfs_log
    # we assume your NIC interface(s) is/are like eth*
    eth_dirs=$(ls -d /sys/class/net/eth*)
    if [ $? -ne 0 ];then
        echo "Failed to find eth*  , sleep 30" >> $dc2_mq_rps_rfs_log
        sleep 30
        eth_dirs=$(ls -d /sys/class/net/eth*)
    fi
    echo "find eth device is : $eth_dirs" >> $dc2_mq_rps_rfs_log
    echo "========  DC2 network setting starts $(date +'%Y-%m-%d %H:%M:%S') ========" >> $dc2_mq_rps_rfs_log

    for i in $eth_dirs
    do
        cur_eth=$(basename $i)
        echo "set and check multiqueue on $cur_eth" >> $dc2_mq_rps_rfs_log
        set_check_multiqueue $cur_eth $dc2_mq_rps_rfs_log
        if [ $? -ne 0 ]; then
            echo "Failed to set multiqueue on $cur_eth" >> $dc2_mq_rps_rfs_log
            ret_value=1
        fi
    done
    
    echo "stop irqbalance service" >> $dc2_mq_rps_rfs_log
    stop_irqblance $dc2_mq_rps_rfs_log
    ret=`set_irq_smpaffinity $dc2_mq_rps_rfs_log`
    if [ $? -ne 0 ];then
        echo "start irqbalance service" >> $dc2_mq_rps_rfs_log
        start_irqblance $dc2_mq_rps_rfs_log
        if [ $? -ne 0 ]; then
            ret_value=1
        fi
    fi

    echo "stop rps " >> $dc2_mq_rps_rfs_log

    stop_rps "${eth_dirs}"

    echo "========  DC2 network setting END $(date +'%Y-%m-%d %H:%M:%S')  ========" >> $dc2_mq_rps_rfs_log
    return $ret_value
}

# DIDI irq program starts here:
main
exit $?
