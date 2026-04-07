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
* Run common playbook
* Update DNS table again with static ip
