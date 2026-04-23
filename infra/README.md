# New Host
This section explains the steps that need to be taken before a new host can be added to the
inventory file.

# Armbian Host
* Connect monitor to discover ip
* Run through root and hla setup
* grab ip address and do the rest from the mac
* Edit hostname
    ```bash

    sudo hostnamectl set-hostname lib-potato-XX
    # this is for potatos
    sudo sed -i 's/lepotato/lib-potato-XX/g' /etc/hosts
    # this for pis
    sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1   lib-pi-XX/' /etc/hosts
    ```
* Copy ssh keys
    ```bash
    ssh-copy-id -i ~/.ssh/hla_id_rsa.pub hla@<node-ip>
    ```
* Update DNS table:
    * Add the IP address of the new host to the DNS table of the router.
* sudo apt update & sudo apt upgrade -y
    * If there are issues with the kernal version. run sudo apt --fix-broken install
    * reboot
* create file /etc/sudoers.d/hla
* add this to the file hla ALL=(ALL) NOPASSWD: ALL
* if you are reflashing an existing node, wipe the fs and lvs on the ssd
* Run common playbook
* Update DNS table again with static ip


## Removing a node
Server (control plane) node:
* `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` — evicts workloads gracefully
* `sudo systemctl stop k3s` — stops the k3s server process on the node
* Remove from etcd:
```bash
# list members
sudo ETCDCTL_API=3 etcdctl   \
    --endpoints=https://127.0.0.1:2379   \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt   \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt   \
    --key=/var/lib/rancher/k3s/server/tls/etcd/client.key   \
member list

# remove member
sudo ETCDCTL_API=3 etcdctl   \
    --endpoints=https://127.0.0.1:2379   \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt   \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt   \
    --key=/var/lib/rancher/k3s/server/tls/etcd/client.key   \
member remove 88c1774a39fb9220
```
* `kubectl delete node <node>` — removes the node object from the cluster

## Adding a server
* When adding a new server, k3s attempts to update the labels on the node.
* However, to do this, it must first check with the longhorn validating webhook to make sure that this is ok
* However, because the CNI for the node has not yet been bootstrapped, it is unable to communicate with the webhook
* This causes a type of deadlock as the k3s server bootstrap can't continue.
* Delete the webhook before trying to add a new server. The deployment will recreate it.

