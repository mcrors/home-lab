# Steps to create an iSCSI target and LUN

* Use the targetcli tool to create the things needed objects
```bash
sudo targetcli
```

* Create a Block Device that is connected to the LVM volume
```bash
cd /backstores/block
create test_lvm_block  /dev/vg_k3s_iscsi/lv_iscsi_test
```

* Create the iSCSI target
```bash
cd /iscsi
create iqn.2025-02.home.lib-pi-06:lib-pi-06-target
```

* Get the initiator iqn from the initiator
```bash
cat /etc/iscsi/initiatorname.iscsi
```

* Create an ACL for the initiator
```bash
cd /iscsi/iqn.2025-02.home.lib-pi-06:lib-pi-06-target/tpg1/acls
create iqn.2025-02.local.lib-pi-04:initiator1
```

* Create a LUN to connect the target to the Block device
```bash
cd /iscsi/iqn.2025-02.home.lib-pi-06:lib-pi-06-target/tpg1/luns
create /backstores/block/test_lvm_block
```

* Save the config and exit
```bash
cd /
saveconfig
exit
```

* Restart the service
```
systemctl restart target
```

* On the initiator discover the target and login
```bash
sudo iscsiadm -m discovery -t sendtargets -p <TARGET_IP>
sudo iscsiadm -m node --login
```

* Verify that the block device appears on the initiator
```bash
lsblk
```




